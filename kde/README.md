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
  positioned at the caret per `DESIGN.md`, bottom-center fallback.

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

Without these (or in apps that stay silent) the pill shows centered
at the bottom edge, like on Hyprland.

Notes:

- Switching windows fades the pill out; it reappears once the new
  caret confirms (or the fallback shows after ~0.6 s). It never gets
  stuck at the old spot.
- Big trees (browsers) are cached, so the first focus in a heavy app
  can take a moment; typing then follows smoothly.
- foot (and other GPU terminals without accessibility support) cannot
  report a caret to anyone — not even to a screen reader — so they
  always use the fallback. Konsole follows the caret.

## Files

- `capspill.py` — daemon: LED poll, AT-SPI caret, D-Bus service,
  KWin script lifecycle, overlay lifecycle
- `kwin-watcher.js` — KWin script (active-window geometry push)
- `shell.qml` — overlay (placement + fades, reads state file)
- `CapsPill.qml` — symlink to the shared capsule
