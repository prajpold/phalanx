# Checked once, from the dispatcher, where the descriptors are still the ones
# the terminal handed us. Inside the pickers every one of them may be a pipe.
phalanx_require_tty() {
  if [ -t 0 ] && [ -t 1 ]; then
    return 0
  fi
  printf 'phalanx: needs an interactive terminal\n' >&2
  return 1
}

_phalanx_fzf_pick() {
  local prompt="$1" hint="$2" out query selection
  out="$(fzf --print-query --layout=reverse --no-scrollbar --pointer='▌' \
             --color='fg:-1,bg:-1,fg+:-1,bg+:-1,hl:cyan,hl+:cyan:bold,pointer:cyan,prompt:cyan,info:dim,footer:dim,footer-border:dim' \
             --prompt="$prompt" --footer="$hint" --footer-border=line)" || true
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
  local root="$1" role="$2" branch candidates prompt

  candidates="$(
    git -C "$root" for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null \
      | sed -e 's|^origin/||' | grep -v '^HEAD$' | sort -u
  )"

  prompt='work branch > '
  [ "$role" = ops ] && prompt='ops branch > '

  branch="$(printf '%s\n' "$candidates" | _phalanx_fzf_pick "$prompt" 'existing branch, or type a new one')"

  [ -n "$branch" ] || return 0
  if [ "$role" = ops ]; then
    phalanx_ops "$branch" "$root"
  else
    phalanx_work "$branch" "$root"
  fi
}

_phalanx_columns() {
  if [ -n "${PHALANX_COMPACT:-}" ]; then
    printf '     age  cat  %-30s agent\n' 'repo/branch'
  else
    printf '   state       age  %-20s %-22s %-11s agent\n' repo branch category
  fi
}

phalanx_list() {
  _phalanx_columns
  phalanx_rows | awk -F'\t' '{ print $5 }'
}

phalanx_pick() {
  local rows out key line target kind cwd root

  case "$(tmux show-option -gqv @phalanx-compact)" in
    on|1|yes) PHALANX_COMPACT=1; export PHALANX_COMPACT ;;
  esac

  rows="$(phalanx_rows)"
  if [ -z "$(printf '%s' "$rows" | tr -d '[:space:]')" ]; then
    phalanx_new_interactive
    return
  fi

  out="$(
    printf '%s\n' "$rows" | fzf --ansi --delimiter=$'\t' --with-nth=5 \
      --layout=reverse --no-scrollbar --pointer='▌' --marker='▌' \
      --color='fg:-1,bg:-1,fg+:-1,bg+:-1,hl:cyan,hl+:cyan:bold,pointer:cyan,prompt:cyan,info:dim,header:dim,footer:dim,footer-border:dim,border:dim,spinner:cyan' \
      --header="$(_phalanx_columns)" \
      --footer='enter attach · ctrl-b work · ctrl-o ops · ctrl-n new · ctrl-x kill · ctrl-r reload' \
      --footer-border=line \
      --expect=ctrl-n,ctrl-x,ctrl-b,ctrl-o \
      --bind="ctrl-r:reload($PHALANX_ROOT/bin/phalanx ls --tsv)"
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
      if [ "$key" = ctrl-o ]; then
        _phalanx_branch_interactive "$root" ops
      else
        _phalanx_branch_interactive "$root" work
      fi
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
