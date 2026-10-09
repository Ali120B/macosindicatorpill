# macospills — macOS-style Caps Lock pill, everywhere

A small ⇪ capsule that appears while Caps Lock is ON, plus a 1 s
input-source flash (`EN`, `AR`, …) on layout switches. One design
(`DESIGN.md`), one backend per compositor:

| Backend      | Dir         | Overlay                                        | Caret source                                  | Status                         |
|--------------|-------------|------------------------------------------------|-----------------------------------------------|--------------------------------|
| Hyprland     | `hyprland/` | Quickshell layer-shell, at-caret (glide, hides off-field) | caret-bridge plugin (text-input rect) | working, see `hyprland/README.md` |
| GNOME 50/51  | `gnome/`    | Shell extension, at-caret (exact follow, hides off-field) | shell's own IBus cursor tracking + in-process layout switch | working, see `gnome/README.md` |
| KDE Plasma 6 | `kde/`      | Quickshell layer-shell, follows caret (smooth) | KWin geometry push + AT-SPI in-window caret   | working, verified in Kate      |

Why per-compositor code: no Linux DE exposes the caret rect to normal
apps. Hyprland keeps it in-compositor (bridge plugin reads it);
GNOME exposes it in-process via IBus (extension); KDE composes KWin
geometry + AT-SPI.
