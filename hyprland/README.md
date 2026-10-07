# macospills — macOS-style Caps Lock pill for Hyprland

A small ⇪ capsule (Quickshell + QtQuick) that appears while Caps Lock
is ON, placed **at the text caret** like macOS. Caps-only, no
layout/num pills.

- Shows while caps is ON (held), hides when it goes off
- At-caret: centered on the caret, 6 px below (above when no room),
  clamped to the monitor, smooth 120 ms follow
- Re-pops when the focused window changes with caps still on (macOS-like)
- Hides when no caret is known (off-field, desktop, XWayland) — same
  call as the KDE backend, no bottom-center fallback
- Click-through overlay, 90ms fade in / 140ms fade out

## Caret sources (best first)

1. **caret-bridge plugin** (`caret-bridge/`) — reads the Wayland
   `text-input-v1/v3` cursor rectangle in-compositor, publishes
   `/tmp/macospills-hypr-caret.json`. Covers kitty/foot/alacritty
   (needs fcitx5 running, see below), GTK, Qt, Firefox,
   Electron/Chromium with `--enable-wayland-ime`.
   XWayland never sends a rect (pill hides there by design).
2. **Neither knows a caret → hidden** (off-field, desktop, XWayland).
   (`capspill-hypr.py`, the old AT-SPI fallback, is retired — it held
   stale per-app rects across tab switches and competed with the
   bridge. Still in the dir for manual use.)

## Run

```bash
./run.sh
```

This starts the overlay, auto-loads the bridge `.so` when built, and
starts `fcitx5 -d` when installed but not running. First build the
bridge once:

```bash
cmake -B caret-bridge/build -DCMAKE_BUILD_TYPE=Release -S caret-bridge
cmake --build caret-bridge/build
```

Hyprland autostart (`hyprland.conf`):

```ini
exec-once = ~/projects/macospills/hyprland/run.sh
```

`run.sh` also starts `fcitx5 -d` when installed but not running —
required for at-caret in terminals (foot/kitty/etc. only send their
cursor rectangle once an input method is present; without one the
pill hides there). GTK/Qt/Firefox follow without it.

Plugins are version-pinned: after every Hyprland update, rebuild the
bridge (`cmake --build caret-bridge/build`) and reload.

## Test without toggling caps

```bash
quickshell ipc -p ~/projects/macospills/hyprland call capspill reveal
quickshell ipc -p ~/projects/macospills/hyprland call capspill hide
cat /tmp/macospills-hypr-caret.json   # bridge: hasCaret true when typing
quickshell ipc -p ~/projects/macospills/hyprland call capspill debug
# live state: capsOn/hasCaret/px/py/opacity
hyprctl macospills:inputs  # text-input table (`>` = focused app)
```

The bridge file also carries `why` + `app` (e.g.
`no_candidate ... cli=1 upd=0` = app binds text-input but sends no
rect — typical without fcitx5 running).

Real toggle test: `wtype -k Caps_Lock` (press again to release), then check
`cat /sys/class/leds/*capslock/brightness` reads `1` and the pill follows
the caret (`grim` it).

## Tune

Top of `shell.qml`: `gap`, `pollMs`, `capsOnFocus`.
Pill look in `CapsPill.qml`: `capsuleColor`, `inkColor`, sizes, timings.

## Files

- `shell.qml` — layer-shell overlay, caret placement, caps polling, IPC
- `CapsPill.qml` — the capsule (arrow-over-bar ⇪, shadow, fades)
- `caret-bridge/` — Hyprland plugin (sole caret source)
- `capspill-hypr.py` — retired AT-SPI fallback (manual use only)
- `run.sh` — launcher (overlay + best-effort plugin/fcitx5 start)
