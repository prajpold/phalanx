_phalanx_goto() {
  local target="$1" session="${1%%:*}"
  tmux select-window -t "$target" 2>/dev/null || true
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$target"
  else
    tmux attach-session -t "=$session"
  fi
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

_phalanx_create_session() {
  local name="$1" path="$2" layout="$3" role="$4" branch="$5" repo="$6"
  local file window command first=1 line

  if tmux has-session -t "=$name" 2>/dev/null; then
    _phalanx_goto "$name:"
    return
  fi

  file="$(_phalanx_layout_file "$path" "$layout")" || {
    printf 'phalanx: no layout %s\n' "${layout:-default}" >&2
    return 1
  }

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
  local path="${1:-$PWD}" layout="${2:-}" root repo branch

  [ -d "$path" ] || { printf 'phalanx: not a directory: %s\n' "$path" >&2; return 1; }
  path="$(cd "$path" && pwd)"

  root="$(_phalanx_repo_root "$path")" || root=""
  repo="${root:+$(basename "$root")}"
  branch="$(git -C "$path" branch --show-current 2>/dev/null)"

  _phalanx_create_session "$(_phalanx_sanitize "$(basename "$path")")" \
    "$path" "$layout" work "$branch" "${repo:-$(basename "$path")}"
}

_phalanx_branch_session() {
  local branch="$1" layout="$2" role="$3" root repo dest
  [ -n "$branch" ] || { printf 'phalanx: branch required\n' >&2; return 1; }

  root="$(_phalanx_repo_root "${4:-$PWD}")" || {
    printf 'phalanx: not a git repository\n' >&2
    return 1
  }
  repo="$(basename "$root")"
  dest="$(_phalanx_ensure_worktree "$root" "$branch")" || return 1

  _phalanx_create_session "$(_phalanx_sanitize "$repo/$branch")" \
    "$dest" "$layout" "$role" "$branch" "$repo"
}

phalanx_work() {
  _phalanx_branch_session "${1:-}" "${PHALANX_WORK_LAYOUT:-default}" work "${2:-$PWD}"
}

phalanx_ops() {
  _phalanx_branch_session "${1:-}" "${PHALANX_OPS_LAYOUT:-ops}" ops "${2:-$PWD}"
}
