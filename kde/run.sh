#!/usr/bin/env bash
# Launch the macOS-style Caps Lock pill on KDE (daemon owns everything:
# KWin watcher + overlay + state). Needs quickshell installed.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$DIR/capspill.py"
