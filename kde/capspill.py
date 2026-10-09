#!/usr/bin/env python3
"""macospills KDE daemon.

Composes the caret position KWin hides from clients:
  screen_caret = KWin window position + AT-SPI in-window caret rect.

  - Caps state: kernel LED (/sys/class/leds/*capslock/brightness).
  - Window position: pushed by kde/kwin-watcher.js (loaded into KWin at
    start, unloaded at exit) over D-Bus.
  - In-window caret: AT-SPI focused text object, WINDOW-relative extents
    (the only space Wayland toolkits answer truthfully in).
  - Emits /tmp/macospills-kde.json for kde/shell.qml (watched, no IPC
    spam): {caps, hide, hasCaret, hasText, termFb, cx,cy,cw,ch,
    wx,wy,ww,wh, layout, fseq} in logical pixels. hasText (a textbox is
    focused) gates the layout flash's bottom-center fallback; termFb
    (silent terminal, caret unknowable) gates the caps pill's
    window-anchored fallback. Otherwise caps hides without a caret.

Needs for at-caret mode: QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 (Qt apps)
and toolkit-accessibility=true (GTK apps). Without them (or where an app
stays silent) it degrades to the on-screen fallback, same as Hyprland.
"""

import glob
import json
import os
import re
import subprocess
import time

import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib
import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_PATH = "/tmp/macospills-kde.json"
BUS_NAME = "org.macospills.kde"
OBJ_PATH = "/pill"
IFACE = "org.macospills.Pill"
SCRIPT_NAME = "macospills"
SCRIPT_PATH = os.path.join(HERE, "kwin-watcher.js")
POLL_CAPS_MS = 150
POLL_CARET_MS = 50
POLL_LAYOUT_MS = 400
REWALK_IDLE_S = 4.0
REWALK_EMPTY_S = 2.0
HASTEXT_TTL_S = 1.0
# Grace hold: keep reporting the last good rect briefly after a loss so
# single-poll toolkit flaps (Kate's tree winks mid-typing) don't blink
# the pill or reset arming. Real focus loss hides ~0.4 s later.
HOLD_S = 0.4
MAX_WALK_NODES = 20000
WALK_BUDGET_S = 0.2
CACHE_TTL_S = 5.0
CACHE_MAX_NODES = 400
PITCH_FALLBACK = 16


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def log(*a):
    print("capspill:", *a, flush=True)


def read_brightness(path):
    try:
        with open(path) as f:
            return f.read().strip() == "1"
    except OSError:
        return False


def output_layout():
    """Enabled outputs as [(x, y, w, h, scale)] from kscreen-doctor.

    Geometry line formats differ across versions — try several patterns;
    blocks with a Scale but no parseable geometry keep None geometry and
    serve as scale fallback (old first-output behavior). Never raises.
    """
    try:
        out = subprocess.run(
            ["kscreen-doctor", "-o"], capture_output=True, text=True, timeout=5
        ).stdout
        clean = re.sub(r"\x1b\[[0-9;]*m", "", out)
        res = []
        for block in clean.split("Output:")[1:]:
            if "enabled" not in block.split("\n", 2)[1]:
                continue
            m = re.search(r"Scale:\s*([\d.]+)", block)
            if not m:
                continue
            scale = float(m.group(1))
            g = (re.search(r"Geometry:\s*(-?\d+),(-?\d+)\s+(\d+)x(\d+)", block) or
                 re.search(r"Geometry:\s*(-?\d+)\s+(-?\d+)\s+(\d+)\s*[xX]\s*(\d+)",
                            block) or
                 re.search(r"Position:\s*(-?\d+),(-?\d+)", block))
            if g and len(g.groups()) >= 4:
                res.append((int(g.group(1)), int(g.group(2)),
                            int(g.group(3)), int(g.group(4)), scale))
            elif g and len(g.groups()) >= 2:
                res.append((int(g.group(1)), int(g.group(2)), 0, 0, scale))
            else:
                res.append((None, None, None, None, scale))
        return res
    except Exception:
        return []


def output_scale():
    """Logical scale of the first enabled output (fallback)."""
    outs = output_layout()
    if outs:
        return outs[0][4] or 1.0
    return 1.0


class PillService(dbus.service.Object):
    def __init__(self, daemon):
        self.daemon = daemon
        bus_name = dbus.service.BusName(BUS_NAME, dbus.SessionBus())
        super().__init__(bus_name, OBJ_PATH)

    @dbus.service.method(IFACE, in_signature="iiiiiiss")
    def ActiveWindow(self, fx, fy, fw, fh, cx, cy, app_id, caption):
        self.daemon.on_window(int(fx), int(fy), int(fw), int(fh),
                              int(cx), int(cy), str(app_id), str(caption))

    @dbus.service.method(IFACE)
    def ToggleLayout(self):
        self.daemon.toggle_layout()


class Daemon:
    def __init__(self):
        self.leds = sorted(glob.glob("/sys/class/leds/*capslock/brightness"))
        self.scale = output_scale()
        self.outputs = output_layout()
        self.outputs_at = time.time()
        self.layout = ""
        self.layout_src = None
        # Focus generation: bumped on every real window change so the
        # overlay can re-arm the first-key gate per field.
        self.focus_seq = 0
        self.caps = None
        self.win = None  # (fx,fy,fw,fh,cx,cy,app_id)
        self.last_json = ""
        self.pitch_cache = {}  # (app, doc) -> pitch
        self.stable = None  # last accepted screen caret rect
        self.pending = None  # big jump awaiting confirmation
        self.text_cache = {}  # app_norm -> (timestamp, [accessibles])
        # Sticky caret node: per-poll fast path (~4 AT-SPI calls) so the
        # 50 ms loop never re-scores whole trees. Full walks only on app
        # change, node death, or a static caret past REWALK_IDLE_S (idle
        # user or a same-app field/tab switch — the rewalk re-resolves).
        self.best = None  # (app_norm, node, text_iface, app_name)
        self.best_at = 0
        self.best_caret = None
        self.best_static_since = 0
        self.hastext_at = 0
        self.hastext_val = False
        self.dbg_winner = ""
        self.held_rect = None
        self.held_win = ""
        self.hold_until = 0
        self.qs_proc = None
        Atspi.init()
        self.desktop = Atspi.get_desktop(0)
        log(f"leds={self.leds} scale={self.scale}")

    # --- subprocess / kwin plumbing ---------------------------------

    def qdbus(self, *args):
        try:
            return subprocess.run(
                ["qdbus6", *args], capture_output=True, text=True, timeout=10
            )
        except Exception as e:
            log("qdbus failed:", e)
            return None

    def load_watcher(self):
        r = self.qdbus("org.kde.KWin", "/Scripting",
                       "org.kde.kwin.Scripting.isScriptLoaded", SCRIPT_NAME)
        if r and r.stdout.strip() == "true":
            self.qdbus("org.kde.KWin", "/Scripting",
                       "org.kde.kwin.Scripting.unloadScript", SCRIPT_NAME)
        r = self.qdbus("org.kde.KWin", "/Scripting",
                       "org.kde.kwin.Scripting.loadScript",
                       SCRIPT_PATH, SCRIPT_NAME)
        log("loadScript ->", (r.stdout.strip() if r else None))
        self.qdbus("org.kde.KWin", "/Scripting",
                   "org.kde.kwin.Scripting.start")

    def unload_watcher(self):
        self.qdbus("org.kde.KWin", "/Scripting",
                   "org.kde.kwin.Scripting.unloadScript", SCRIPT_NAME)

    def start_overlay(self):
        self.qs_proc = subprocess.Popen(["quickshell", "-p", HERE])
        log("overlay started")

    def stop_overlay(self):
        if self.qs_proc:
            self.qs_proc.terminate()
            self.qs_proc = None

    # --- state -------------------------------------------------------

    def scale_at(self, x, y):
        """Scale of the output containing (x, y); layout refreshes at
        most every 60 s (hotplug) so polls stay cheap."""
        try:
            if time.time() - self.outputs_at > 60:
                self.outputs = output_layout()
                self.outputs_at = time.time()
            for ox, oy, ow, oh, s in self.outputs:
                if ox is None:
                    continue
                if ow and oh and not (ox <= x < ox + ow and oy <= y < oy + oh):
                    continue
                if s:
                    return s
        except Exception:
            pass
        return self.scale or 1.0

    def on_window(self, fx, fy, fw, fh, cx, cy, app_id, caption):
        app_id = str(app_id)
        if fw <= 0 or fh <= 0 or not app_id:
            # desktop / no active window (watcher sends -1/empty on
            # minimize-to-desktop): drop everything so the pill hides
            # instead of sticking at the old caret
            self.win = None
            self.stable = None
            self.pending = None
            self.best = None
            self.held_rect = None
            self.hold_until = 0
            self.emit_state()
            return
        if self.win is None or self.win[6] != app_id:
            self.stable = None
            self.pending = None
            self.best = None
            self.held_rect = None
            self.hold_until = 0
            self.text_cache.pop(norm(app_id), None)
            self.focus_seq += 1
            log(f"active: app={app_id!r} frame=({fx},{fy},{fw},{fh}) "
                f"client=({cx},{cy}) caption={caption[:40]!r}")
        elif (self.win[0], self.win[1], self.win[2], self.win[3]) != \
                (fx, fy, fw, fh):
            # same app, different window/geometry (second Kate window,
            # tiling move): old caret is stale — require fresh confirm
            self.stable = None
            self.pending = None
            self.best = None
            self.held_rect = None
            self.hold_until = 0
            self.focus_seq += 1
        self.win = (fx, fy, fw, fh, cx, cy, app_id)

    def poll_caps(self):
        try:
            on = any(read_brightness(p) for p in self.leds)
            if on != self.caps:
                self.caps = on
                if on:
                    # fresh toggle: old stable may be from another window
                    # while caps was off — require fresh confirmation
                    self.stable = None
                    self.pending = None
                    self.best = None
                    self.held_rect = None
                    self.hold_until = 0
                self.emit_state()
        except Exception as e:
            log("caps poll failed:", e)
        return True

    # --- layout pill ---------------------------------------------------
    # macOS flashes the input source ~1 s on switch. Sources, best first:
    # fcitx5 (CurrentInputMethod — run.sh starts it anyway) covers
    # fcitx-managed switching; native Plasma XKB groups are probed via
    # org.kde.keyboard and logged (report the log line if the pill never
    # fires — the service path varies). No source -> pill stays off.

    @staticmethod
    def short_im(name):
        """'keyboard-us' -> 'US', 'keyboard-ara' -> 'ARA'."""
        short = (name or "").split("-")[-1].upper()
        return short[:6] if short else ""

    def discover_layout(self):
        r = self.qdbus("org.fcitx.Fcitx5", "/controller",
                       "org.fcitx.Fcitx.Controller1.CurrentInputMethod")
        if r and r.returncode == 0 and r.stdout.strip():
            self.layout_src = "fcitx"
            self.layout = self.short_im(r.stdout.strip())
            log(f"layout source: fcitx5 ({self.layout})")
            return
        r = self.qdbus("org.kde.keyboard", "/Layouts")
        if r and r.returncode == 0:
            log("org.kde.keyboard /Layouts methods:",
                r.stdout.strip().split("\n")[:8])
        else:
            log("org.kde.keyboard: no /Layouts (native probe off)")
        self.layout_src = None
        log("layout source: none (layout pill off)")

    def read_layout(self):
        if self.layout_src == "fcitx":
            r = self.qdbus("org.fcitx.Fcitx5", "/controller",
                           "org.fcitx.Fcitx.Controller1.CurrentInputMethod")
            if r and r.returncode == 0:
                return self.short_im(r.stdout.strip())
        return self.layout

    def poll_layout(self):
        try:
            cur = self.read_layout()
            if cur != self.layout:
                self.layout = cur
                self.emit_state()
        except Exception as e:
            log("layout poll failed:", e)
        return True

    def read_layout_full(self):
        if self.layout_src == "fcitx":
            r = self.qdbus("org.fcitx.Fcitx5", "/controller",
                           "org.fcitx.Fcitx.Controller1.CurrentInputMethod")
            if r and r.returncode == 0:
                return r.stdout.strip()
        return ""

    def toggle_layout(self):
        """Ctrl+Shift+Space (KWin global shortcut): flip fcitx5
        keyboard-us <-> keyboard-ara, mirroring
        hyprland/layout-toggle.lua. The layout poll picks up the change
        and flashes the pill."""
        if self.layout_src != "fcitx":
            log("toggle: no fcitx source, ignored")
            return
        cur = self.read_layout_full()
        target = "keyboard-ara" if cur == "keyboard-us" else "keyboard-us"
        try:
            r = subprocess.run(["fcitx5-remote", "-s", target],
                               capture_output=True, text=True, timeout=5)
            log(f"toggle: {cur} -> {target} rc={r.returncode}")
        except Exception as e:
            log("toggle failed:", e)

    # --- AT-SPI caret -------------------------------------------------

    def walk(self, acc, out):
        if len(out) >= MAX_WALK_NODES or time.time() > self._deadline:
            return out
        out.append(acc)
        try:
            n = acc.get_child_count()
        except Exception:
            return out
        for i in range(min(n, 100)):
            try:
                c = acc.get_child_at_index(i)
            except Exception:
                continue
            if c is not None:
                self.walk(c, out)
                if len(out) >= MAX_WALK_NODES:
                    break
        return out

    TEXT_ROLES = ("text", "editable text", "entry", "terminal",
                    "password text")

    def text_nodes(self, app_acc, app_norm):
        """All live text objects of an app; cached TTL seconds so heavy
        trees (browsers) are walked rarely and polls stay cheap."""
        now = time.time()
        hit = self.text_cache.get(app_norm)
        if hit and now - hit[0] < CACHE_TTL_S:
            live = []
            for node in hit[1]:
                try:
                    node.get_state_set()
                    live.append(node)
                    if len(live) >= CACHE_MAX_NODES:
                        break
                except Exception:
                    continue
            if live:
                return live
        found = []
        for node in self.walk(app_acc, []):
            try:
                role = node.get_role_name()
            except Exception:
                continue
            if role not in self.TEXT_ROLES:
                continue
            try:
                if node.get_text_iface() is None:
                    continue
            except Exception:
                continue
            found.append(node)
            if len(found) >= CACHE_MAX_NODES:
                break
        self.text_cache[app_norm] = (now, found)
        return found

    def focused_ancestor(self, node, up=5):
        p = node
        for _ in range(up):
            try:
                p = p.get_parent()
            except Exception:
                return False
            if p is None:
                return False
            try:
                if p.get_state_set().contains(Atspi.StateType.FOCUSED):
                    return True
            except Exception:
                pass
        return False

    @staticmethod
    def cand_meta(node, nchars, caret, ncands, how):
        try:
            nm = node.get_name() or "?"
        except Exception:
            nm = "?"
        return (f"{how}/{ncands}cands name={nm[:24]!r} "
                f"nchars={nchars} caret={caret}")

    def find_text(self, app_acc, app_norm, allow_empty=False,
                  focused_only=False):
        """Best caret-bearing text object. Preference order: directly
        FOCUSED, then a focused ancestor (Kate tabs: the document never
        takes FOCUS itself — its view does — so plain scoring can park
        the pill in the inactive tab), then score. Stashes winner meta
        in self.dbg_winner for the state log."""
        cands = []  # (score, focused, node, ti, nchars, caret)
        for node in self.text_nodes(app_acc, app_norm):
            try:
                states = node.get_state_set()
                ti = node.get_text_iface()
            except Exception:
                continue
            if ti is None:
                continue
            try:
                nchars = ti.get_character_count()
                caret = ti.get_caret_offset()
            except Exception:
                continue
            if nchars == 0 and not allow_empty:
                continue
            if not states.contains(Atspi.StateType.SHOWING):
                continue
            focused = states.contains(Atspi.StateType.FOCUSED)
            if focused_only and not focused:
                continue
            score = min(nchars, 500)
            if caret > 0:
                score += 500
            if focused:
                score += 10000
            cands.append((score, focused, node, ti, nchars, caret))
        if not cands:
            self.dbg_winner = "none/0cands"
            return None, None
        cands.sort(key=lambda c: -c[0])
        # A directly-focused node always sorts first (+10000 dominates).
        if cands[0][1] or focused_only:
            w = cands[0]
            self.dbg_winner = self.cand_meta(w[2], w[4], w[5],
                                             len(cands), "focused")
            return w[2], w[3]
        for w in cands[:40]:
            if self.focused_ancestor(w[2]):
                self.dbg_winner = self.cand_meta(w[2], w[4], w[5],
                                                 len(cands), "ancestor")
                return w[2], w[3]
        w = cands[0]
        self.dbg_winner = self.cand_meta(w[2], w[4], w[5],
                                         len(cands), "score")
        return w[2], w[3]

    def pitch(self, app_name, doc, ti, caret, nchars):
        key = (app_name, doc)
        if key in self.pitch_cache:
            return self.pitch_cache[key]
        rows = {}

        def ext(off):
            try:
                e = ti.get_character_extents(off, Atspi.CoordType.WINDOW)
                return (e.x, e.y, e.width, e.height)
            except Exception:
                return None

        for off in range(max(0, caret - 80), min(nchars, caret + 80)):
            r = ext(off)
            if not r:
                continue
            rows.setdefault(r[1], r)
            if len(rows) >= 3:
                break
        ys = sorted(rows)
        p = PITCH_FALLBACK
        if len(ys) >= 2:
            diffs = [b - a for a, b in zip(ys, ys[1:]) if b - a > 0]
            if diffs:
                p = sorted(diffs)[len(diffs) // 2]
        self.pitch_cache[key] = p
        return p

    def node_rect(self, node, ti, name, nchars, frame):
        """Screen caret rect for a known node (stabilized), or None.

        AT-SPI WINDOW extents on this stack are logical pixels (verified:
        dividing by the output scale pulls every rect toward the screen
        origin by the scale factor — exactly the observed offset), so no
        scale division: window origin + extents, rounded."""
        fx, fy, fw, fh, cx, cy = frame[:6]
        try:
            ox = cx if cx >= 0 else fx
            oy = cy if cy >= 0 else fy
            if nchars > 0:
                try:
                    caret = ti.get_caret_offset()
                    idx = max(0, min(caret - 1 if caret > 0 else 0, nchars - 1))
                    e = ti.get_character_extents(idx, Atspi.CoordType.WINDOW)
                except Exception:
                    # Flaky toolkit mid-keystroke (Kate serves a stale
                    # snapshot for a poll): hold the last good rect
                    # instead of jumping to the field box or hiding.
                    return self.stable
                h = e.height if e.height > 0 else self.pitch(
                    name, self.doc_name(node), ti, caret, nchars)
                w = e.width if e.width > 0 else 7
                rect = (ox + e.x, oy + e.y, w, h)
            else:
                # Empty field: no characters to measure — use the field's
                # own box so the pill sits under it instead of fallback.
                b = node.get_component_iface().get_extents(
                    Atspi.CoordType.WINDOW)
                if b.width <= 0 or b.height <= 0:
                    return None
                rect = (ox + b.x, oy + b.y, 8,
                        min(b.height, PITCH_FALLBACK * 2))
        except Exception:
            return None
        return self.stabilize(rect, (fx, fy, fw, fh))

    def best_rect(self, node, ti, frame, name):
        """Fast path: query the sticky node directly (~4 AT-SPI calls).
        Returns (rect|None, caret|None); None rect means dead/hidden/
        unreadable — caller rewalks."""
        try:
            states = node.get_state_set()
            if not states.contains(Atspi.StateType.SHOWING):
                return None, None
            nchars = ti.get_character_count()
        except Exception:
            return None, None
        caret = None
        if nchars > 0:
            try:
                caret = ti.get_caret_offset()
            except Exception:
                pass
        return self.node_rect(node, ti, name, nchars, frame), caret

    def caret_rect(self):
        """(rect, node, ti, app_name) — full tree resolve."""
        if not self.win:
            return None, None, None, None
        fx, fy, fw, fh, cx, cy, app_id = self.win
        want = norm(app_id)
        self._deadline = time.time() + WALK_BUDGET_S
        for i in range(self.desktop.get_child_count()):
            try:
                app = self.desktop.get_child_at_index(i)
                name = norm(app.get_name())
            except Exception:
                continue
            if not want or (want not in name and name not in want):
                continue
            node, ti = self.find_text(app, want, focused_only=True)
            if ti is None:
                # some editors (Kate) never mark the document FOCUSED —
                # focused-ancestor pass inside find_text covers the
                # active tab; then empty fields
                node, ti = self.find_text(app, want)
            if ti is None:
                node, ti = self.find_text(app, want, allow_empty=True)
            if ti is None:
                return None, None, None, None
            try:
                nchars = ti.get_character_count()
            except Exception:
                return None, None, None, None
            return (self.node_rect(node, ti, name, nchars, self.win),
                    node, ti, name)
        return None, None, None, None

    # Active terminals are text-focused by construction (prompt input),
    # even when they expose no AT-SPI tree (foot and other GPU
    # terminals report a caret to nobody). Match by substring so
    # wrapped ids (org.kde.konsole, footclient) hit.
    TERMINALS = ("konsole", "foot", "kitty", "alacritty", "wezterm",
                 "ghostty", "gnome-terminal", "ptyxis", "tilix",
                 "terminator", "xterm", "urxvt", "contour", "rio",
                 "tabby", "warp")

    def focused_text(self):
        """True when a textbox is selected (see _focused_scan). Fast
        paths first: silent terminals, then the sticky node; the full
        tree scan runs at most every HASTEXT_TTL_S."""
        if not self.win:
            return False
        want = norm(self.win[6])
        # Silent terminals never appear in the AT-SPI tree — check first.
        if want and any(t in want for t in self.TERMINALS):
            return True
        if self.best and self.best[0] == want:
            try:
                st = self.best[1].get_state_set()
                if (st.contains(Atspi.StateType.FOCUSED)
                        and st.contains(Atspi.StateType.SHOWING)):
                    return True
            except Exception:
                pass
        now = time.time()
        if now - self.hastext_at < HASTEXT_TTL_S:
            return self.hastext_val
        self.hastext_val = self._focused_scan(want)
        self.hastext_at = now
        return self.hastext_val

    def _focused_scan(self, want):
        """Full scan for a focused, showing text object (or a terminal
        window's implicit focus); desktop / plain windows stay hidden."""
        self._deadline = time.time() + WALK_BUDGET_S
        try:
            n = self.desktop.get_child_count()
        except Exception:
            return False
        for i in range(n):
            try:
                app = self.desktop.get_child_at_index(i)
                name = norm(app.get_name())
            except Exception:
                continue
            if not want or (want not in name and name not in want):
                continue
            for node in self.text_nodes(app, want):
                try:
                    states = node.get_state_set()
                except Exception:
                    continue
                try:
                    if (states.contains(Atspi.StateType.FOCUSED)
                            and states.contains(Atspi.StateType.SHOWING)):
                        return True
                except Exception:
                    continue
            return False
        return False

    def caret_info(self):
        """(rect | None, has_text: bool). Sticky-node fast path keeps
        polls O(1) (~4 AT-SPI calls); full walks only on app change,
        node death, or a caret static past REWALK_IDLE_S (idle user or
        a same-app field/tab switch — the rewalk re-resolves). Brief
        losses hold the last good rect for HOLD_S (flap cover)."""
        if not self.win:
            self.best = None
            return None, False
        want = norm(self.win[6])
        now = time.time()
        rect = self.fast_rect(want, now)
        if rect is None:
            rect = self.resolve_rect(want, now)
        if rect is not None:
            self.held_rect = rect
            self.held_win = want
            self.hold_until = now + HOLD_S
            return rect, True
        if (self.held_rect is not None and now < self.hold_until
                and want and want == self.held_win):
            return self.held_rect, True
        return None, self.focused_text()

    def fast_rect(self, want, now):
        """Sticky-node fast path, or None (rewalk needed)."""
        if self.best and self.best[0] == want:
            _, node, ti, name = self.best
            rect, caret = self.best_rect(node, ti, self.win, name)
            if rect is not None:
                if caret is None:
                    # Empty field: no liveness signal — re-resolve on TTL
                    # (freshly typed text may live in a new node) so the
                    # pill never parks on a stale empty snapshot.
                    if now - self.best_static_since > REWALK_EMPTY_S:
                        self.best_static_since = now
                    else:
                        return rect
                elif self.fresh_caret(caret, now):
                    return rect
                # else: static too long (idle or a same-app field/tab
                # switch) — fall through to rewalk
            # else: node died/hidden — fall through to rewalk
        return None

    def resolve_rect(self, want, now):
        """Full tree walk; re-stickies the winner."""
        rect, node, ti, name = self.caret_rect()
        if node is not None:
            self.best = (want, node, ti, name)
            self.best_at = now
            try:
                self.best_caret = ti.get_caret_offset()
            except Exception:
                self.best_caret = None
            self.best_static_since = now
        else:
            self.best = None
        return rect

    def fresh_caret(self, caret, now):
        """True when the sticky node is still the live field: a moving
        caret, or static for less than REWALK_IDLE_S."""
        if caret != self.best_caret:
            self.best_caret = caret
            self.best_static_since = now
            return True
        return now - self.best_static_since < REWALK_IDLE_S

    def stabilize(self, rect, frame):
        """Reject garbage rects: must sit inside the window, and moves
        past typing scale need a confirming second poll (kills the
        fly-around on focus changes and flaky mid-keystroke snapshots
        while keeping typing moves instant)."""
        fx, fy, fw, fh = frame
        m = 64
        inside = (rect[0] + rect[2] / 2 >= fx - m and
                  rect[0] + rect[2] / 2 <= fx + fw + m and
                  rect[1] >= fy - m and
                  rect[1] <= fy + fh + m)
        if not inside:
            self.pending = None
            return self.stable
        if self.stable is None:
            self.stable = rect
            self.pending = None
            return rect
        move = abs(rect[0] - self.stable[0]) + abs(rect[1] - self.stable[1])
        if move < 60:
            self.stable = rect
            self.pending = None
            return rect
        if (self.pending and
                abs(rect[0] - self.pending[0]) < 8 and
                abs(rect[1] - self.pending[1]) < 8):
            self.stable = rect
            self.pending = None
            return rect
        self.pending = rect
        return self.stable

    @staticmethod
    def doc_name(node):
        p = node
        for _ in range(6):
            try:
                n = p.get_name()
                if n and "." in n:
                    return n
            except Exception:
                pass
            try:
                p = p.get_parent()
            except Exception:
                break
        return "?"

    def poll_caret(self):
        try:
            self.emit_state()
        except Exception as e:
            log("caret poll failed:", e)
        return True

    def emit_state(self):
        rect, has_text = self.caret_info()
        # Caps: no caret, no pill — except silent terminals (always a
        # textbox, caret unknowable): window-anchored fallback, unarmed.
        # Layout flash (shell-side): caret preferred, bottom-center
        # fallback while a textbox is focused, hidden otherwise.
        if self.win:
            fx, fy, fw, fh = self.win[0], self.win[1], self.win[2], self.win[3]
            want = norm(self.win[6])
        else:
            fx = fy = fw = fh = 0
            want = ""
        term_fb = (rect is None and has_text and want and
                   any(t in want for t in self.TERMINALS))
        if rect:
            state = {"caps": bool(self.caps), "hide": False,
                     "hasCaret": True, "hasText": True, "termFb": False,
                     "cx": rect[0], "cy": rect[1],
                     "cw": rect[2], "ch": rect[3],
                     "wx": fx, "wy": fy, "ww": fw, "wh": fh,
                     "layout": self.layout or "",
                     "fseq": self.focus_seq}
        else:
            state = {"caps": bool(self.caps), "hide": True,
                     "hasCaret": False, "hasText": bool(has_text),
                     "termFb": bool(term_fb),
                     "cx": 0, "cy": 0, "cw": 0, "ch": 0,
                     "wx": fx, "wy": fy, "ww": fw, "wh": fh,
                     "layout": self.layout or "",
                     "fseq": self.focus_seq}
        js = json.dumps(state)
        if js != self.last_json:
            self.last_json = js
            log(f"state caps={state['caps']} caret={state['hasCaret']} "
                f"text={state['hasText']} "
                f"rect=({state['cx']},{state['cy']},{state['cw']},{state['ch']}) "
                f"layout={state['layout']} fseq={state['fseq']} "
                f"{self.dbg_winner}")
            try:
                with open(STATE_PATH, "w") as f:
                    f.write(js)
            except OSError as e:
                log("state write failed:", e)

    # --- main ----------------------------------------------------------

    def run(self):
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        PillService(self)
        self.load_watcher()
        self.discover_layout()
        self.start_overlay()
        self.caps = any(read_brightness(p) for p in self.leds)
        self.emit_state()
        GLib.timeout_add(POLL_CAPS_MS, self.poll_caps)
        GLib.timeout_add(POLL_CARET_MS, self.poll_caret)
        GLib.timeout_add(POLL_LAYOUT_MS, self.poll_layout)
        try:
            GLib.MainLoop().run()
        except KeyboardInterrupt:
            pass
        finally:
            self.stop_overlay()
            self.unload_watcher()


if __name__ == "__main__":
    Daemon().run()
