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
    spam): {caps: bool, caret: {x,y,w,h} | null} in logical pixels.

Needs for at-caret mode: QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 (Qt apps)
and toolkit-accessibility=true (GTK apps). Without them (or where an app
stays silent) it degrades to the on-screen fallback, same as Hyprland.
"""

import glob
import json
import os
import re
import subprocess
import sys
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
POLL_CARET_MS = 150
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


def output_scale():
    """Logical scale of the first enabled output (kscreen-doctor)."""
    try:
        out = subprocess.run(
            ["kscreen-doctor", "-o"], capture_output=True, text=True, timeout=5
        ).stdout
        clean = re.sub(r"\x1b\[[0-9;]*m", "", out)
        for block in clean.split("Output:")[1:]:
            if "enabled" not in block.split("\n", 2)[1]:
                continue
            m = re.search(r"Scale:\s*([\d.]+)", block)
            if m:
                return float(m.group(1))
    except Exception:
        pass
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


class Daemon:
    def __init__(self):
        self.leds = sorted(glob.glob("/sys/class/leds/*capslock/brightness"))
        self.scale = output_scale()
        self.caps = None
        self.win = None  # (fx,fy,fw,fh,cx,cy,app_id)
        self.last_json = ""
        self.pitch_cache = {}  # (app, doc) -> pitch
        self.stable = None  # last accepted screen caret rect
        self.pending = None  # big jump awaiting confirmation
        self.text_cache = {}  # app_norm -> (timestamp, [accessibles])
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

    def on_window(self, fx, fy, fw, fh, cx, cy, app_id, caption):
        app_id = str(app_id)
        if fw <= 0 or fh <= 0 or not app_id:
            # desktop / no active window (watcher sends -1/empty on
            # minimize-to-desktop): drop everything so the pill hides
            # instead of sticking at the old caret
            self.win = None
            self.stable = None
            self.pending = None
            self.emit_state()
            return
        if self.win is None or self.win[6] != app_id:
            self.stable = None
            self.pending = None
            self.text_cache.pop(norm(app_id), None)
            log(f"active: app={app_id!r} frame=({fx},{fy},{fw},{fh}) "
                f"client=({cx},{cy}) caption={caption[:40]!r}")
        elif (self.win[0], self.win[1], self.win[2], self.win[3]) != \
                (fx, fy, fw, fh):
            # same app, different window/geometry (second Kate window,
            # tiling move): old caret is stale — require fresh confirm
            self.stable = None
            self.pending = None
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
                self.emit_state()
        except Exception as e:
            log("caps poll failed:", e)
        return True

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

    def find_text(self, app_acc, app_norm, allow_empty=False,
                  focused_only=False):
        """Best caret-bearing text object. Focused-first: FOCUSED+SHOWING
        nodes win over big background documents (browsers) — the old
        scorer preferred large nchars and picked the wrong field."""
        best = None
        best_score = -1
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
            if score > best_score:
                best_score = score
                best = (node, ti)
        return best if best else (None, None)

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

    def caret_rect(self):
        """(x, y, w, h) in logical screen pixels, or None."""
        if not self.win:
            return None
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
                # fall back to any showing text, then empty fields
                node, ti = self.find_text(app, want)
            if ti is None:
                node, ti = self.find_text(app, want, allow_empty=True)
            if ti is None:
                return None
            try:
                nchars = ti.get_character_count()
            except Exception:
                return None
            ox = cx if cx >= 0 else fx
            oy = cy if cy >= 0 else fy
            s = self.scale or 1.0
            if nchars > 0:
                try:
                    caret = ti.get_caret_offset()
                except Exception:
                    return None
                idx = max(0, min(caret - 1 if caret > 0 else 0, nchars - 1))
                try:
                    e = ti.get_character_extents(idx, Atspi.CoordType.WINDOW)
                except Exception:
                    return None
                h = e.height if e.height > 0 else self.pitch(
                    name, self.doc_name(node), ti, caret, nchars)
                w = e.width if e.width > 0 else 7
                rect = (round((ox + e.x) / s), round((oy + e.y) / s),
                        round(w / s), round(h / s))
            else:
                # Empty field: no characters to measure — use the field's
                # own box so the pill sits under it instead of fallback.
                try:
                    b = node.get_component_iface().get_extents(
                        Atspi.CoordType.WINDOW)
                except Exception:
                    return None
                if b.width <= 0 or b.height <= 0:
                    return None
                rect = (round((ox + b.x) / s), round((oy + b.y) / s),
                        round(8 / s),
                        round(min(b.height, PITCH_FALLBACK * 2) / s))
            return self.stabilize(rect, (fx, fy, fw, fh))
        return None

    def stabilize(self, rect, frame):
        """Reject garbage rects: must sit inside the window, and big jumps
        need a confirming second poll (kills the fly-around on focus
        changes while keeping typing moves instant)."""
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
        if move < 400:
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
        caret = self.caret_rect() if self.caps else None
        # No caret, no pill: when Caps is on but no textbox is focused,
        # hide instead of falling back (explicit user call).
        hide = caret is None
        if caret:
            state = {"caps": True, "hide": False, "hasCaret": True,
                     "cx": caret[0], "cy": caret[1],
                     "cw": caret[2], "ch": caret[3]}
        else:
            state = {"caps": bool(self.caps), "hide": hide,
                     "hasCaret": False,
                     "cx": 0, "cy": 0, "cw": 0, "ch": 0}
        js = json.dumps(state)
        if js != self.last_json:
            self.last_json = js
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
        self.start_overlay()
        self.caps = any(read_brightness(p) for p in self.leds)
        self.emit_state()
        GLib.timeout_add(POLL_CAPS_MS, self.poll_caps)
        GLib.timeout_add(POLL_CARET_MS, self.poll_caret)
        try:
            GLib.MainLoop().run()
        except KeyboardInterrupt:
            pass
        finally:
            self.stop_overlay()
            self.unload_watcher()


if __name__ == "__main__":
    Daemon().run()
