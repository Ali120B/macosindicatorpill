#!/usr/bin/env python3
"""macospills Hyprland AT-SPI fallback.

Second-priority caret source behind caret-bridge/ (the Hyprland plugin
that reads text-input cursor rectangles in-compositor).

  screen_caret = hyprctl activewindow position + AT-SPI in-window caret.

  - In-window caret: AT-SPI focused text object, WINDOW-relative extents
    (the only space Wayland toolkits answer truthfully in).
  - Window position: `hyprctl activewindow -j` (`at` + `size`, already
    logical layout coords — do NOT divide by scale).
  - Emits /tmp/macospills-hypr-atspi.json for shell.qml:
      {"hasCaret": bool, "x","y","w","h": int}  (logical px)

shell.qml prefers caret-bridge; this file only matters where the bridge
reports null (toolkits that don't send cursor rectangles, XWayland,
missing plugin). When this also has nothing, shell.qml falls back to
bottom-center.

Needs for at-caret mode: QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 (Qt apps)
and toolkit-accessibility=true (GTK apps). Terminals without AT-SPI
(foot, kitty, alacritty) are covered by the bridge instead — this is
the complementary half.
"""

import glob
import json
import os
import re
import subprocess
import time

import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

STATE_PATH = "/tmp/macospills-hypr-atspi.json"
POLL_S = 0.15
MAX_WALK_NODES = 20000
WALK_BUDGET_S = 0.2
CACHE_TTL_S = 5.0
CACHE_MAX_NODES = 400
PITCH_FALLBACK = 16


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def log(*a):
    print("capspill-hypr:", *a, flush=True)


def read_brightness(path):
    try:
        with open(path) as f:
            return f.read().strip() == "1"
    except OSError:
        return False


class Daemon:
    def __init__(self):
        self.leds = sorted(glob.glob("/sys/class/leds/*capslock/brightness"))
        self.win = None  # (x, y, w, h, app_class)
        self.last_json = ""
        self.pitch_cache = {}
        self.stable = None
        self.pending = None
        self.text_cache = {}
        Atspi.init()
        self.desktop = Atspi.get_desktop(0)
        log(f"leds={self.leds}")

    # --- window ------------------------------------------------------

    def poll_window(self):
        """Active window geometry from hyprctl. None on desktop/no window."""
        try:
            out = subprocess.run(
                ["hyprctl", "activewindow", "-j"],
                capture_output=True, text=True, timeout=5,
            ).stdout
            info = json.loads(out)
        except Exception:
            return
        if not info or not info.get("mapped", True):
            self.set_win(None)
            return
        try:
            at = info.get("at") or [0, 0]
            size = info.get("size") or [0, 0]
            cls = str(info.get("class") or info.get("initialClass") or "")
            if size[0] <= 0 or size[1] <= 0:
                self.set_win(None)
                return
            self.set_win((int(at[0]), int(at[1]),
                          int(size[0]), int(size[1]), cls))
        except Exception:
            self.set_win(None)

    def set_win(self, win):
        if win is None:
            if self.win is not None:
                self.win = None
                self.stable = None
                self.pending = None
            return
        if self.win is None or self.win[4] != win[4]:
            # app changed: drop stale caret + cached tree (new doc)
            self.stable = None
            self.pending = None
            self.text_cache.pop(norm(win[4]), None)
            log(f"active: app={win[4]!r} at=({win[0]},{win[1]},{win[2]},{win[3]})")
        elif (self.win[0], self.win[1], self.win[2], self.win[3]) != \
                (win[0], win[1], win[2], win[3]):
            # same app, moved/resized (new window, tiling change):
            # old caret is stale — require fresh confirmation
            self.stable = None
            self.pending = None
        self.win = win

    # --- AT-SPI caret --------------------------------------------------

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

    def find_text(self, app_acc, app_norm, focused_only=False):
        """Best caret-bearing text object.

        Focused-first: FOCUSED+SHOWING nodes win over big background
        documents (browsers), which was the old wrong-pick bug.
        """
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
            if nchars == 0:
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
        if best:
            return best
        if not focused_only:
            return (None, None)
        return (None, None)

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

    def caret_rect(self):
        """(x, y, w, h) in logical screen pixels, or None."""
        if not self.win:
            return None
        wx, wy, ww, wh, app_id = self.win
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
            # focused-first, then any, then empty fields
            node, ti = self.find_text(app, want, focused_only=True)
            if ti is None:
                node, ti = self.find_text(app, want)
            if ti is None:
                # empty field: use its own box so the pill sits under
                # it instead of falling back
                node2, ti2 = None, None
                for n in self.text_nodes(app, want):
                    try:
                        st = n.get_state_set()
                        if not st.contains(Atspi.StateType.FOCUSED):
                            continue
                        if not st.contains(Atspi.StateType.SHOWING):
                            continue
                        b = n.get_component_iface().get_extents(
                            Atspi.CoordType.WINDOW)
                    except Exception:
                        continue
                    if b.width > 0 and b.height > 0:
                        node2 = n
                        break
                if node2 is None:
                    return None
                try:
                    b = node2.get_component_iface().get_extents(
                        Atspi.CoordType.WINDOW)
                except Exception:
                    return None
                rect = (wx + b.x, wy + b.y, 8,
                        min(b.height, PITCH_FALLBACK * 2))
                return self.stabilize(rect, (wx, wy, ww, wh))
            try:
                nchars = ti.get_character_count()
            except Exception:
                return None
            if nchars <= 0:
                return None
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
            rect = (wx + e.x, wy + e.y, w, h)
            return self.stabilize(rect, (wx, wy, ww, wh))
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

    # --- main ----------------------------------------------------------

    def emit(self, rect):
        if rect:
            state = {"hasCaret": True, "x": int(rect[0]), "y": int(rect[1]),
                     "w": int(rect[2]), "h": int(rect[3])}
        else:
            state = {"hasCaret": False, "x": 0, "y": 0, "w": 0, "h": 0}
        js = json.dumps(state)
        if js != self.last_json:
            self.last_json = js
            try:
                tmp = STATE_PATH + ".tmp"
                with open(tmp, "w") as f:
                    f.write(js)
                os.replace(tmp, STATE_PATH)
            except OSError as e:
                log("state write failed:", e)

    def run(self):
        # ensure a state file exists so QML never waits on nothing
        self.emit(None)
        while True:
            try:
                caps = any(read_brightness(p) for p in self.leds) \
                    if self.leds else False
                self.poll_window()
                if not caps or not self.win:
                    if caps and not self.win:
                        self.stable = None
                        self.pending = None
                    self.emit(None)
                else:
                    self.emit(self.caret_rect())
            except Exception as e:
                log("poll failed:", e)
            time.sleep(POLL_S)


if __name__ == "__main__":
    Daemon().run()
