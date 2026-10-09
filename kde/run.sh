#!/usr/bin/env bash
# Launch the macOS-style Caps Lock pill on KDE (daemon owns everything:
# KWin watcher + overlay + state). Needs quickshell installed.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Layout source + IME presence for caret rects in terminals: best effort,
# start fcitx5 if installed and not already running.
if command -v fcitx5 >/dev/null 2>&1 && ! pgrep -x fcitx5 >/dev/null 2>&1; then
  fcitx5 -d >/tmp/macospills-fcitx5.log 2>&1 || true
fi

exec python3 "$DIR/capspill.py"
