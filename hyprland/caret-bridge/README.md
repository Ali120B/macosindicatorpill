# caret-bridge — in-compositor caret publisher for macospills

Hyprland owns the text caret (Wayland `text-input-v1/v3`
`set_cursor_rectangle`), and exposes no caret command over IPC.
This ~300-line plugin reads it inside the compositor and publishes
`/tmp/macospills-hypr-caret.json` for `../shell.qml`:

```json
{"hasCaret":true,"x":123,"y":456,"w":2,"h":20}
{"hasCaret":false,"x":0,"y":0,"w":0,"h":0}
```

Coords are compositor logical pixels — the same space Quickshell
layer-shell uses. No scale math.

## Probe order

Freshest **rect** wins among enabled direct inputs (v1/v3 compete by
when the box itself last *changed*, not by commit activity — an
enable/commit can arrive for a field switch while the state still
holds the previous field's box). Keystrokes (incl. backspace) and
field/tab switches that move the caret always change the box; a
vacated field's box goes quiet. Then:

1. Freshest focus wins (`direct-v3-focus`): an enable within 3 s
   means "focus just arrived here" even if the box hasn't re-committed
   (back to a tab whose caret never moved) — it outranks a fresher box
   on the blurred field, but only when text-consistent (box recorded
   for the current surrounding text). Otherwise the freshest changed
   box wins (`direct-v3` / `direct-v1`, steady typing).
   Contradicting single-line commits (text shrank but the rect jumped
   right, e.g. Gecko backspace transients) hold the old box for that
   probe (`held-transient`). A *different* object
   enabled after the winner's box+focus means a box-less new field:
   hide (`field-switch`) instead of showing stale. Same-object text
   replace without a fresh box means a reused input (Ctrl-T in Gecko):
   hide (`field-switch-text`).
   Enabled winners additionally need *liveness*: a commit or enable
   within 5 s and after the last window-title change — Gecko goes
   silent on navigation/close/blur (no commit, no disable), so an
   unrefreshed rect stops being "the caret". Typing refreshes
   constantly. Idling with the field still focused keeps the pill via
   relay confirmation (`direct-v3-idle` — the relay still reports the
   same rect now, no trailing disable, no navigation since the commit);
   silent blurs clear the relay and still hide.
2. Enabled but empty box with fresh commits (`selection-hold` —
   select-all collapses the caret; holds last pos while commits flow)
3. Disabled-but-updated whose last event was a recent commit
   (`direct-v3-stale`, ≤5 s — typing in clients that never set
   enabled; a trailing disable hides immediately)
4. Relay (`relay` — compositor-blessed focus, covers missed objects),
   gated on the client's own input vitality since it carries no
   timestamps (an ungated stale relay reintroduces forever-stuck)
5. 1 s same-client cache (`cached` — transient protocol gaps, never
   across a trailing disable: a disable newer than the cached caret
   hides instantly instead of lingering)
6. Null (`no_caret ...` — no enabled field: the overlay **hides**,
   it never guesses; also `window_hidden` for minimized/covered
   windows and `no_focus_surface` for empty workspaces)

Degenerate = fully empty box only; a zero-width but tall box is a
real caret line in an empty field (pill uses w=2).

Event-driven: text-input commit/enable/disable, keyboard focus,
window active/close/title, workspace switch, monitor focus — plus a
0.5 s wall-clock backstop (TTLs only expire when a probe runs, and
silent blurs emit nothing). A title rename counts as navigation even
with a nearby commit (Ctrl-Tab right after typing); tiny mutations
(dirty markers, counts) count only when isolated. Focus changes also
bump a `win` sequence in the JSON so the overlay re-pops without
polling `hyprctl`. Writes are atomic (tmp+rename) and only on change.
`why` + `app` keys in the JSON are diagnostics for `cat` (ignored by
the overlay).

## Debug

```bash
hyprctl macospills:inputs  # full text-input table: en/upd/box per
                           # object, event ages; `>` marks the focused
                           # client's rows
cat /tmp/macospills-hypr-caret.json  # what the overlay sees
tail -n 30 /tmp/macospills-caret.log  # every published state with
                           # timestamps — reproduce a bug, then paste
                           # this, no timing needed
```

## Build

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
hyprctl plugin load "$(pwd)/build/macospills-caret-bridge.so"
```

Hyprland plugins are version-pinned: after every Hyprland update,
rebuild (`cmake --build build`) and reload. `../run.sh` auto-loads the
`.so` when present.

Autostart (`hyprland.conf`):

```ini
exec-once = ~/projects/macospills/hyprland/run.sh
```

## Debug

- `cat /tmp/macospills-hypr-caret.json` — should flip to
  `hasCaret:true` when a text field is focused (terminal with fcitx
  running, editor, browser URL bar with `--enable-wayland-ime` for
  Chromium/Electron). `why` tells you which source won.
- XWayland never sends a cursor rect — null by design, the overlay
  hides there (same policy as KDE).
