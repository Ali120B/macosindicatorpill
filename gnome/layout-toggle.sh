#!/usr/bin/env bash
# Cycle GNOME input sources (e.g. English <-> Arabic) for binding to
# Ctrl+Shift+Space. Changing `current` fires the extension's layout
# flash (1 s at the caret), so no extra wiring is needed.
#
# Setup:
#   1. Have ≥2 sources (Settings → Keyboard → Input Sources).
#   2. Point the command below at this file's real path, then run:
#        gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
#          "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']"
#        gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ name 'Toggle input source'
#        gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ command '/path/to/layout-toggle.sh'
#        gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/ binding '<Primary><Shift>space'
set -euo pipefail

cur=$(gsettings get org.gnome.desktop.input-sources current | tr -dc '0-9')
n=$(gsettings get org.gnome.desktop.input-sources mru-sources | grep -o "('" | wc -l)
if [ "${n:-0}" -lt 2 ]; then
  echo "layout-toggle: need 2+ input sources" >&2
  exit 1
fi
gsettings set org.gnome.desktop.input-sources current "$(( (cur + 1) % n ))"
