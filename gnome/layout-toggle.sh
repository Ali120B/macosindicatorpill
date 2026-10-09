#!/usr/bin/env bash
# macospills GNOME layout toggle — RETIRED as a switcher.
#
# Why retired: this script used to write
#   org.gnome.desktop.input-sources current
# but that key is DEPRECATED and ignored by the shell (see
# /usr/share/glib-2.0/schemas/org.gnome.desktop.input-sources.gschema.xml),
# so it never actually switched layouts. And `mru-sources` is written BY
# the shell after a switch, not read to trigger one — writing it doesn't
# switch either. The only reliable switch path is the shell's own
# InputSourceManager (Mutter xkb + IBus engine together), which the
# extension now calls in-process on Ctrl+Shift+Space. No script needed.
#
# What to do:
#   1. REMOVE the old media-keys custom binding for Ctrl+Shift+Space
#      (it would double-fire with the extension). This script does that
#      for you when run once — or run the gsettings commands below.
#   2. Keep the extension enabled. Ctrl+Shift+Space just works, and the
#      pill flashes on real switches (Super+Space, top-bar menu, and
#      Ctrl+Shift+Space alike) whenever a textbox is focused.
#
# Migration (removes a custom0 binding named 'Toggle input source'):
set -u
CUSTOM=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
name=$(gsettings get org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${CUSTOM} name 2>/dev/null || true)
if echo "$name" | grep -qi "toggle input source"; then
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "@as []"
    gsettings reset org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${CUSTOM} name 2>/dev/null || true
    gsettings reset org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${CUSTOM} command 2>/dev/null || true
    gsettings reset org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${CUSTOM} binding 2>/dev/null || true
    echo "macospills: removed legacy media-keys custom0 'Toggle input source'."
    echo "macospills: Ctrl+Shift+Space is now owned by the extension — nothing else to set up."
else
    echo "macospills: no legacy 'Toggle input source' binding found at custom0."
    echo "macospills: if Ctrl+Shift+Space does nothing, make sure the extension is enabled;"
    echo "macospills: if it double-switches, delete your media-keys custom binding for it:"
    echo "  gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \"@as []\""
fi
