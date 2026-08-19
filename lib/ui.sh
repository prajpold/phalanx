_phalanx_require_tty() {
  [ -t 1 ] && return 0
  printf 'phalanx: needs an interactive terminal\n' >&2
  return 1
}

_phalanx_fzf_pick() {
  local prompt="$1" header="$2" out query selection
  _phalanx_require_tty || return 1
  out="$(fzf --print-query --prompt="$prompt" --header="$header")" || true
  query="$(printf '%s\n' "$out" | sed -n 1p)"
  selection="$(printf '%s\n' "$out" | sed -n 2p)"
  printf '%s\n' "${selection:-$query}"
}

_phalanx_pick_path() {
  local roots="${PHALANX_ROOTS:-$HOME/repos}"
  printf '%s\n' "$roots" | tr ':' '\n' | while IFS= read -r root; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null
  done | sort | _phalanx_fzf_pick 'new session > ' 'pick a repo, or type a path'
}

phalanx_new_interactive() {
  local path
  path="$(_phalanx_pick_path)"
  [ -n "$path" ] || return 0
  case "$path" in "~"*) path="$HOME${path#\~}" ;; esac
  phalanx_new "$path"
}

_phalanx_branch_interactive() {
  local root="$1" role="$2" branch

  if [ "$role" = ops ]; then
    branch="$(phalanx_envs "$root" | _phalanx_fzf_pick 'ops branch > ' 'env branches from config, or type one')"
  else
    branch="$(
      git -C "$root" for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null \
        | sed -e 's|^origin/||' | grep -v '^HEAD$' | sort -u \
        | _phalanx_fzf_pick 'work branch > ' 'existing branch, or type a new one'
    )"
  fi

  [ -n "$branch" ] || return 0
  if [ "$role" = ops ]; then
    phalanx_ops "$branch" "$root"
  else
    phalanx_work "$branch" "$root"
  fi
}

phalanx_pick() {
  local rows out key line target kind cwd root
  _phalanx_require_tty || return 1

  rows="$(phalanx_rows)"
  if [ -z "$(printf '%s' "$rows" | tr -d '[:space:]')" ]; then
    phalanx_new_interactive
    return
  fi

  out="$(
    printf '%s\n' "$rows" | fzf --ansi --delimiter=$'\t' --with-nth=5 \
      --header='enter: attach · ctrl-b: work branch · ctrl-o: ops session · ctrl-n: new repo · ctrl-x: kill · ctrl-r: reload' \
      --expect=ctrl-n,ctrl-x,ctrl-b,ctrl-o \
      --preview='tmux capture-pane -p -t {1} 2>/dev/null | tail -40' \
      --preview-window='right,50%,border-left' \
      --bind="ctrl-r:reload($PHALANX_ROOT/bin/phalanx ls)"
  )" || return 0

  key="$(printf '%s\n' "$out" | sed -n 1p)"
  line="$(printf '%s\n' "$out" | sed -n 2p)"

  if [ "$key" = ctrl-n ]; then
    phalanx_new_interactive
    return
  fi

  [ -n "$line" ] || return 0
  target="$(printf '%s' "$line" | cut -f1)"
  kind="$(printf '%s' "$line" | cut -f4)"
  cwd="$(printf '%s' "$line" | cut -f3)"

  case "$key" in
    ctrl-b|ctrl-o)
      root="$(_phalanx_repo_root "$cwd")" || {
        printf 'phalanx: %s is not in a git repository\n' "$cwd" >&2
        return 1
      }
      [ "$key" = ctrl-o ] && _phalanx_branch_interactive "$root" ops \
                          || _phalanx_branch_interactive "$root" work
      return
      ;;
  esac

  if [ -z "$target" ]; then
    printf 'phalanx: this %s agent is not running in a tmux pane, nothing to attach to\n' "$kind" >&2
    return 1
  fi

  case "$key" in
    ctrl-x) _phalanx_kill "$target" ;;
    *)      _phalanx_goto "$target" ;;
  esac
}

_phalanx_kill() {
  local session="${1%%:*}" reply
  printf 'kill tmux session %s? [y/N] ' "$session"
  read -r reply
  case "$reply" in
    y|Y) tmux kill-session -t "=$session" ;;
    *)   printf 'aborted\n' ;;
  esac
}

phalanx_work_interactive() {
  local root
  root="$(_phalanx_repo_root "${1:-$PWD}")" || {
    printf 'phalanx: not a git repository\n' >&2
    return 1
  }
  _phalanx_branch_interactive "$root" work
}

phalanx_ops_interactive() {
  local root
  root="$(_phalanx_repo_root "${1:-$PWD}")" || {
    printf 'phalanx: not a git repository\n' >&2
    return 1
  }
  _phalanx_branch_interactive "$root" ops
}
