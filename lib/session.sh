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

# Matched on the window name rather than the command, which leaves you free to
# wrap or flag the agent.
_phalanx_layout_has_agent() {
  awk '$1 == "agent" { found = 1 } END { exit !found }' "$1"
}

_phalanx_create_session() {
  local session="$1" path="$2" layout="$3" strict="$4" location="$5" root="$6" repo="$7"
  local file window command first=1 line

  if tmux has-session -t "=$session" 2>/dev/null; then
    _phalanx_goto "$session:"
    return
  fi

  file="$(_phalanx_layout_file "$path" "$layout")" || {
    printf 'phalanx: no layout %s\n' "${layout:-default}" >&2
    return 1
  }

  if [ -n "$strict" ] && ! _phalanx_layout_has_agent "$file"; then
    printf 'phalanx: %s declares no agent window\n' "$file" >&2
    printf 'phalanx: a session without one reports no state, which is what the\n' >&2
    printf 'phalanx: dashboard is for. Add a window named agent:\n' >&2
    printf 'phalanx:   agent\tclaude\n' >&2
    printf 'phalanx: or pass --layout to ask for one deliberately.\n' >&2
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    window="${line%%[[:space:]]*}"
    command="${line#"$window"}"
    command="${command#"${command%%[![:space:]]*}"}"

    if [ "$first" -eq 1 ]; then
      tmux new-session -d -s "$session" -c "$path" -n "$window" || return 1
      first=0
    else
      tmux new-window -t "=$session:" -c "$path" -n "$window"
    fi
    # send-keys rather than passing the command to tmux, so quitting nvim or
    # claude leaves a shell behind instead of closing the window.
    [ -n "$command" ] && tmux send-keys -t "=$session:$window" "$command" C-m
  done < "$file"

  if [ "$first" -eq 1 ]; then
    printf 'phalanx: layout %s is empty\n' "$file" >&2
    return 1
  fi

  tmux set-option -t "$session" @phalanx-location "$location"
  tmux set-option -t "$session" @phalanx-root "$root"
  tmux set-option -t "$session" @phalanx-repo "$repo"

  _phalanx_goto "$session:{start}"
}

_phalanx_session_name() {
  _phalanx_sanitize "$(basename "$1")/$2"
}

_phalanx_session_worktree() {
  printf '%s/worktrees/%s/%s\n' "$PHALANX_HOME" "$1" "$2"
}

# A worktree belongs to the session, not to a branch, so the branch inside it is
# free to move — which is the point when a session carries a stack of them.
_phalanx_add_worktree() {
  local root="$1" repo="$2" name="$3" branch="${4:-$3}" dest
  dest="$(_phalanx_session_worktree "$repo" "$name")"

  if [ -d "$dest" ]; then
    printf '%s\n' "$dest"
    return
  fi

  mkdir -p "$(dirname "$dest")"
  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$root" worktree add "$dest" "$branch" >&2 || return 1
  elif git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$root" worktree add --track -b "$branch" "$dest" "origin/$branch" >&2 || return 1
  else
    git -C "$root" worktree add -b "$branch" "$dest" >&2 || return 1
  fi

  _phalanx_provision "$root" "$dest"
  printf '%s\n' "$dest"
}

# Two sessions in one checkout means two agents writing to the same working tree,
# and a branch switch in either silently moves the other.
_phalanx_confirm_main() {
  local root="$1" existing reply
  existing="$(
    tmux list-sessions -F '#{session_name}	#{@phalanx-location}	#{@phalanx-root}' 2>/dev/null \
      | awk -F'\t' -v want="$root" '$2 == "main" && $3 == want { print $1 }'
  )"
  [ -n "$existing" ] || return 0

  printf 'phalanx: these already run in this checkout:\n' >&2
  printf '%s\n' "$existing" | sed 's/^/  /' >&2
  printf 'phalanx: they share one working tree, and a branch switch in one moves\n' >&2
  printf 'phalanx: the others without telling them.\n' >&2
  printf 'create it anyway? [y/N] ' >&2
  read -r reply
  case "$reply" in
    y|Y) return 0 ;;
    *) printf 'aborted\n' >&2; return 1 ;;
  esac
}

phalanx_session() {
  local name="$1" worktree="$2" branch="$3" layout="$4" cwd="${5:-$PWD}"
  local root repo dest location strict=""

  [ -n "$name" ] || { printf 'phalanx: a session name is required\n' >&2; return 1; }

  root="$(_phalanx_repo_root "$cwd")" || {
    printf 'phalanx: not a git repository\n' >&2
    return 1
  }
  repo="$(basename "$root")"

  if [ -n "$worktree" ]; then
    dest="$(_phalanx_add_worktree "$root" "$repo" "$name" "$branch")" || return 1
    location=worktree
  else
    _phalanx_confirm_main "$root" || return 1
    dest="$root"
    location=main
  fi

  [ -n "$layout" ] || strict=strict
  _phalanx_create_session "$(_phalanx_session_name "$root" "$name")" \
    "$dest" "$layout" "$strict" "$location" "$root" "$repo"
}
