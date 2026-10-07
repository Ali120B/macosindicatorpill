#!/usr/bin/env bash
# Launch the macOS-style Caps Lock pill on Hyprland.
# Starts the AT-SPI fallback daemon + the Quickshell overlay.
# The caret-bridge plugin (in-compositor, primary caret source) is loaded
# separately — see caret-bridge/README, or run:
#   hyprctl plugin load "$DIR/caret-bridge/build/macospills-caret-bridge.so"
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Terminals (foot/kitty/wezterm) only send their caret rectangle once an
# input method is present — without one the bridge sees `upd=0` and the
# pill falls back to bottom-center. Best effort: start fcitx5 if it's
# installed and not already running (standard, also serves CJK input).
if command -v fcitx5 >/dev/null 2>&1 && ! pgrep -x fcitx5 >/dev/null 2>&1; then
  fcitx5 -d >/tmp/macospills-fcitx5.log 2>&1 || true
fi

# AT-SPI fallback daemon — DISABLED by default. It kept a per-app stable
# rect across tab switches and injected stale competing positions while
# the bridge had the truth (same-app stabilize retention). The bridge
# (text-input rects) covers terminals (with fcitx), GTK, Qt, Gecko and
# Electron; where it reports null the pill now hides by policy.
# To re-enable (e.g. XWayland carets via a11y), uncomment:
# if command -v python3 >/dev/null 2>&1; then
#   python3 "$DIR/capspill-hypr.py" >/tmp/macospills-hypr-atspi.log 2>&1 &
#   ATSPI_PID=$!
#   trap 'kill "$ATSPI_PID" 2>/dev/null || true' EXIT
# fi

# best effort: load the bridge if built and not already loaded
SO="$DIR/caret-bridge/build/macospills-caret-bridge.so"
if [ -f "$SO" ] && command -v hyprctl >/dev/null 2>&1; then
  if ! hyprctl plugins list 2>/dev/null | grep -q "macospills-caret-bridge"; then
    hyprctl plugin load "$SO" >/dev/null 2>&1 || true
  fi
fi

quickshell -p "$DIR"
