#!/usr/bin/env bash
PHALANX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

key="$(tmux show-option -gqv @phalanx-key)"
tmux bind-key "${key:-g}" display-popup -E -w 90% -h 80% "$PHALANX_DIR/bin/phalanx pick"
