#!/usr/bin/env bash
PHALANX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

option() {
  local value
  value="$(tmux show-option -gqv "$1")"
  printf '%s\n' "${value:-$2}"
}

bind_popup() {
  local key="$1" command="$2"
  [ "$key" = none ] && return 0
  # -d keeps the popup in the current pane's directory, which is how the git
  # commands find the repo to act on.
  tmux bind-key "$key" display-popup -E -d '#{pane_current_path}' \
    -w "$(option @phalanx-width 90%)" -h "$(option @phalanx-height 80%)" \
    "$PHALANX_DIR/bin/phalanx $command"
}

bind_popup "$(option @phalanx-key g)" pick
bind_popup "$(option @phalanx-work-key b)" work
bind_popup "$(option @phalanx-ops-key e)" ops
