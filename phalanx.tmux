#!/usr/bin/env bash
PHALANX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

option() {
  local value
  value="$(tmux show-option -gqv "$1")"
  printf '%s\n' "${value:-$2}"
}

SHELL_NAME="$(option @phalanx-shell bash)"
WIDTH="$(option @phalanx-width 90%)"
HEIGHT="$(option @phalanx-height 80%)"
TITLE="#[align=centre,fg=cyan,bold] phalanx $("$PHALANX_DIR/bin/phalanx" --version) "

bind_popup() {
  local key="$1" command="$2"
  [ "$key" = none ] && return 0
  # -EE keeps the popup open when the command fails, otherwise the error text
  # disappears with the popup. -d runs it where the current pane is, which is how
  # the branch commands find the repo to act on.
  tmux bind-key "$key" display-popup -EE -d '#{pane_current_path}' \
    -w "$WIDTH" -h "$HEIGHT" -b rounded -S 'fg=colour8' -T "$TITLE" \
    "$SHELL_NAME -lc '$PHALANX_DIR/bin/phalanx $command'"
}

bind_popup "$(option @phalanx-key g)" pick
bind_popup "$(option @phalanx-work-key b)" work
bind_popup "$(option @phalanx-bare-key e)" bare
