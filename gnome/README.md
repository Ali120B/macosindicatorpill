# macospills on GNOME Shell 50/51

Shell extension. Caps pill (⇪, kernel LED) plus input-source flash,
both placed at the IBus text caret — no accessibility switch needed,
the extension uses the same cursor tracking as the shell's own
candidate popup.

Behavior (per `../DESIGN.md`):

- Caps pill shows only after live typing in the focused field
  (first-key arming), only while a textbox is selected.
- Layout flash (`EN`, `AR`, …) shows 1 s on every real switch with a
  textbox focused — no keypress needed. At the caret when one is
  known, monitor fallback pre-first-keystroke, hidden on the desktop.
- `Ctrl+Shift+Space` is owned by the extension and cycles input
  sources via the shell's own `InputSourceManager` (the only path that
  really switches). `Super+Space` and the top-bar menu flash too.

## Install

Needs ≥2 input sources (Settings → Keyboard → Input Sources) and a
readable caps LED (`cat /sys/class/leds/*capslock/brightness`).

```bash
UUID=macospills@ali120b.github.io
DST=~/.local/share/gnome-shell/extensions/$UUID
rm -rf "$DST" && cp -r gnome/$UUID "$DST"
glib-compile-schemas "$DST/schemas"
gnome-extensions enable $UUID
```

Then **re-log** (Wayland has no shell restart; disable/enable does
not reload extension code).

If you used the old `layout-toggle.sh` media-keys binding, delete it —
it wrote the deprecated `current` key (ignored by the shell, switched
nothing) and would double-fire with the extension:

```bash
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "@as []"
```

(`layout-toggle.sh` now just performs this migration and exits.)

To change the toggle accelerator, edit `toggle-layout` in
`schemas/org.gnome.shell.extensions.macospills.gschema.xml`,
recompile, re-login.

## Debug

- `cat /tmp/macospills-caret.log` — caret rects + follow/drop reasons,
  written only while a layout flash is live.
- Looking Glass (`Alt+F2` → `lg` → Evaluator):
  `Main.panel.statusArea.keyboard._inputSourceManager.currentSource.shortName`
- After any code change: copy files over, recompile schemas if touched,
  re-login. There is no faster reload on Wayland.

## Files

- `macospills@ali120b.github.io/extension.js` — pill, caret tracking,
  layout switch + flash
- `macospills@ali120b.github.io/schemas/` — `toggle-layout` keybinding
  schema (compile with `glib-compile-schemas`)
- `macospills@ali120b.github.io/metadata.json` — Shell 50/51
- `macospills@ali120b.github.io/{stylesheet.css,caps.svg}` — capsule look
- `layout-toggle.sh` — retired switcher, now a migration helper
