# macospills on KDE Plasma 6

At-caret ⇪ pill. KWin hides both halves of the caret from clients, so
this composes them:

- **Window position** — `kwin-watcher.js`, loaded into KWin at daemon
  start (`/Scripting loadScript`, no package install, unloaded on exit),
  pushes active-window frame+client geometry over D-Bus.
- **In-window caret** — AT-SPI focused text object, WINDOW-relative
  extents (the only space Wayland toolkits answer truthfully in).
  Qt/Kate reports zero height, so line pitch is measured from
  neighboring rows and cached per document.
- **Overlay** — `shell.qml` (Quickshell layer-shell, works on KWin),
  tracks the caret exactly per `DESIGN.md` (direct-set, no glide).
  Caps: no caret, no pill (no fallback). Layout flash: caret
  preferred, bottom-center fallback while a textbox is focused.

## Run

```bash
./run.sh
```

Autostart: add `~/projects/macospills/kde/run.sh` in
System Settings → Autostart.

## Caret requirements (else fallback mode)

- Qt apps: `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`
  (put `export QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` in
  `~/.config/plasma-workspace/env/ats.sh`)
- GTK apps: `gsettings set org.gnome.desktop.interface toolkit-accessibility true`

Without these (or in apps that stay silent) there is no caret to
track: the layout flash (which needs only a focused textbox) uses the
bottom-center fallback, and the caps pill hides — except silent
terminals (foot and friends report a caret to nobody but always hold
a prompt), where it shows window-anchored while caps is on, unarmed
(no caret signal exists to arm with).

Notes:

- Switching windows hides the pill; it reappears after the first
  keypress in the new field (first-key arming). It never gets stuck at
  the old spot.
- Big trees (browsers) are cached, so the first focus in a heavy app
  can take a moment; typing then follows smoothly.
- foot (and other GPU terminals without accessibility support) cannot
  report a caret to anyone — not even to a screen reader — so they
  always use the fallback. Konsole follows the caret.

## Files

- `capspill.py` — daemon: LED poll, AT-SPI caret, D-Bus service,
  KWin script lifecycle, overlay lifecycle, layout source
- `kwin-watcher.js` — KWin script (active-window geometry push)
- `shell.qml` — overlay (placement + fades, reads state file)
- `CapsPill.qml` — symlink to the shared capsule
- `LayoutPill.qml` — symlink to the shared layout flash (1 s)
