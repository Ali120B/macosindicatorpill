-- Toggle keyboard layout English <-> Arabic on Ctrl+Shift+Space.
--
-- fcitx5 owns layout switching (Hyprland `switchxkblayout` loses to
-- fcitx's IM state, so the switch never sticks). Needs keyboard-us +
-- keyboard-ara in the fcitx5 Default group (`fcitx5-configtool`, or add
-- a `[Groups/0/Items/1]` block with `Name=keyboard-ara` to
-- ~/.config/fcitx5/profile while fcitx5 is STOPPED, then start it).
-- Silence fcitx's own switch box so only our pill shows:
--   ~/.config/fcitx5/config -> [Behavior] ShowInputMethodInformation=False
--
-- Paste in keybinds.lua (the switcher pings our pill over IPC because
-- the compositor layout event doesn't fire for fcitx switches):
--   hl.bind("CTRL + SHIFT + Space", hl.dsp.exec_cmd("sh -c 'if [ \"$(fcitx5-remote -n)\" = keyboard-us ]; then N=keyboard-ara; S=AR; else N=keyboard-us; S=EN; fi; fcitx5-remote -s \"$N\"; quickshell ipc -p ~/projects/macospills/hyprland call capspill flashLayout \"$S\"'"))
--
-- The caret-bridge still flashes the pill for compositor-side switches.

hl.bind("CTRL + SHIFT + Space", hl.dsp.exec_cmd("sh -c 'if [ \"$(fcitx5-remote -n)\" = keyboard-us ]; then N=keyboard-ara; S=AR; else N=keyboard-us; S=EN; fi; fcitx5-remote -s \"$N\"; quickshell ipc -p ~/projects/macospills/hyprland call capspill flashLayout \"$S\"'"))
