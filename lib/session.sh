# switch-client works inside display-popup, where TMUX is set but TMUX_PANE is
# not, so probe it rather than deciding from the environment.
_phalanx_goto() {
  local target="$1" session="${1%%:*}"
  tmux select-window -t "$target" 2>/dev/null || true

  if tmux switch-client -t "$target" 2>/dev/null; then
    return 0
  fi
  if tmux attach-session -t "=$session" 2>/dev/null; then
    return 0
  fi

  printf 'phalanx: could not attach to %s\n' "$target" >&2
  return 1
}

_phalanx_sanitize() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_/-' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

_phalanx_layout_file() {
  local path="$1" layout="$2" config="${XDG_CONFIG_HOME:-$HOME/.config}/phalanx/layouts"

  if [ -z "$layout" ] && [ -f "$path/.phalanx" ]; then
    printf '%s\n' "$path/.phalanx"
    return
  fi
  layout="${layout:-default}"
  for candidate in "$config/$layout" "$PHALANX_ROOT/layouts/$layout"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

# The state column is the point of the dashboard, so a session that is meant to
# run an agent has to declare the window that runs it. Matched on the window name
# rather than the command, which leaves you free to wrap or flag it.
_phalanx_layout_has_agent() {
  awk '$1 == "agent" { found = 1 } END { exit !found }' "$1"
}

_phalanx_create_session() {
  local name="$1" path="$2" layout="$3" branch="$4" repo="$5" strict="$6"
  local file window command first=1 line role

  if tmux has-session -t "=$name" 2>/dev/null; then
    _phalanx_goto "$name:"
    return
  fi

  file="$(_phalanx_layout_file "$path" "$layout")" || {
    printf 'phalanx: no layout %s\n' "${layout:-default}" >&2
    return 1
  }

  if _phalanx_layout_has_agent "$file"; then
    role=agent
  elif [ -n "$strict" ]; then
    printf 'phalanx: %s declares no agent window\n' "$file" >&2
    printf 'phalanx: a session that is meant to run one reports no state without it,\n' >&2
    printf 'phalanx: which is what the dashboard is for. Add a window named agent:\n' >&2
    printf 'phalanx:   agent\tclaude\n' >&2
    printf 'phalanx: or name a layout explicitly to ask for a session without one.\n' >&2
    return 1
  else
    role=plain
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    window="${line%%[[:space:]]*}"
    command="${line#"$window"}"
    command="${command#"${command%%[![:space:]]*}"}"

    if [ "$first" -eq 1 ]; then
      tmux new-session -d -s "$name" -c "$path" -n "$window" || return 1
      first=0
    else
      tmux new-window -t "=$name:" -c "$path" -n "$window"
    fi
    # send-keys rather than passing the command to tmux, so quitting nvim or
    # claude leaves a shell behind instead of closing the window.
    [ -n "$command" ] && tmux send-keys -t "=$name:$window" "$command" C-m
  done < "$file"

  if [ "$first" -eq 1 ]; then
    printf 'phalanx: layout %s is empty\n' "$file" >&2
    return 1
  fi

  tmux set-option -t "$name" @phalanx-role "$role"
  tmux set-option -t "$name" @phalanx-branch "$branch"
  tmux set-option -t "$name" @phalanx-repo "$repo"

  _phalanx_goto "$name:{start}"
}

phalanx_new() {
  local path="${1:-$PWD}" layout="${2:-}" root repo branch strict=""

  [ -d "$path" ] || { printf 'phalanx: not a directory: %s\n' "$path" >&2; return 1; }
  path="$(cd "$path" && pwd)"

  root="$(_phalanx_repo_root "$path")" || root=""
  repo="${root:+$(basename "$root")}"
  branch="$(git -C "$path" branch --show-current 2>/dev/null)"

  [ -n "$layout" ] || strict=strict

  _phalanx_create_session "$(_phalanx_sanitize "$(basename "$path")")" \
    "$path" "$layout" "$branch" "${repo:-$(basename "$path")}" "$strict"
}

_phalanx_branch_session() {
  local branch="$1" layout="$2" root repo dest strict=""
  [ -n "$branch" ] || { printf 'phalanx: branch required\n' >&2; return 1; }

  root="$(_phalanx_repo_root "${3:-$PWD}")" || {
    printf 'phalanx: not a git repository\n' >&2
    return 1
  }
  repo="$(basename "$root")"
  dest="$(_phalanx_ensure_worktree "$root" "$branch")" || return 1

  [ -n "$layout" ] || strict=strict

  _phalanx_create_session "$(_phalanx_sanitize "$repo/$branch")" \
    "$dest" "$layout" "$branch" "$repo" "$strict"
}

phalanx_work() {
  _phalanx_branch_session "${1:-}" "${2:-}" "${3:-$PWD}"
}

_phalanx_bare_layout() {
  local value
  value="$(tmux show-option -gqv @phalanx-bare-layout 2>/dev/null)"
  printf '%s\n' "${value:-bare}"
}

phalanx_bare() {
  _phalanx_branch_session "${1:-}" "$(_phalanx_bare_layout)" "${2:-$PWD}"
}
