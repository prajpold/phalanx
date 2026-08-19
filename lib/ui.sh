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
             --highlight-line --color="$(_phalanx_colors)" \
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
  done | sort | _phalanx_fzf_pick 'new session > ' 'pick a repo, or type a path · esc goes back'
}

phalanx_new_interactive() {
  local path
  path="$(_phalanx_pick_path)"
  [ -n "$path" ] || return "$PHALANX_BACK"
  case "$path" in "~"*) path="$HOME${path#\~}" ;; esac
  phalanx_new "$path"
}

_phalanx_branch_interactive() {
  local root="$1" layout="$2" branch candidates prompt

  candidates="$(
    git -C "$root" for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null \
      | sed -e 's|^origin/||' | grep -v '^HEAD$' | sort -u
  )"

  prompt='work branch > '
  [ -n "$layout" ] && prompt="$layout branch > "

  branch="$(printf '%s\n' "$candidates" | _phalanx_fzf_pick "$prompt" 'existing branch, or type a new one · esc goes back')"

  [ -n "$branch" ] || return "$PHALANX_BACK"
  phalanx_work "$branch" "$layout" "$root"
}

phalanx_work_interactive() {
  local root
  if ! root="$(_phalanx_repo_root "${1:-$PWD}")"; then
    printf 'phalanx: not a git repository\n' >&2
    return 1
  fi
  _phalanx_branch_interactive "$root" ""
}

phalanx_bare_interactive() {
  local root
  if ! root="$(_phalanx_repo_root "${1:-$PWD}")"; then
    printf 'phalanx: not a git repository\n' >&2
    return 1
  fi
  _phalanx_branch_interactive "$root" "$(_phalanx_bare_layout)"
}

# Returned by a picker the user backed out of, so the caller redraws instead of
# treating it as a finished action.
PHALANX_BACK=2

_phalanx_notice() {
  printf '%s\n' "$@" >&2
  printf '\npress any key to go back ' >&2
  read -r -n 1 _ 2>/dev/null || read -r _
  printf '\n' >&2
}

_phalanx_highlight() {
  local value
  value="$(tmux show-option -gqv @phalanx-highlight 2>/dev/null)"
  printf '%s\n' "${value:-238}"
}

_phalanx_colors() {
  printf 'fg:-1,bg:-1,fg+:-1,bg+:%s,hl:cyan,hl+:cyan:bold,pointer:cyan:bold,%s\n' \
    "$(_phalanx_highlight)" \
    'prompt:cyan,info:dim,header:dim,footer:dim,footer-border:dim,border:dim,spinner:cyan'
}

_phalanx_columns() {
  if [ -n "${PHALANX_COMPACT:-}" ]; then
    printf '     age  cat  %-30s agent\n' 'repo/branch'
  elif [ -n "${1:-}" ]; then
    printf '   state       age  %-20s %-22s %-18s %-11s agent\n' \
      repo branch 'checked out' category
  else
    printf '   state       age  %-20s %-22s %-11s agent\n' repo branch category
  fi
}

_phalanx_diverged() {
  awk -F'\t' '$9 != "" { print 1; exit }'
}

phalanx_list() {
  local rows
  rows="$(phalanx_rows)"
  _phalanx_columns "$(printf '%s\n' "$rows" | _phalanx_diverged)"
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | awk -F'\t' '{ print $5 }'
}

phalanx_pick() {
  local rows out key line target kind cwd pid root status diverged

  case "$(tmux show-option -gqv @phalanx-compact)" in
    on|1|yes) PHALANX_COMPACT=1; export PHALANX_COMPACT ;;
  esac

  while :; do
    rows="$(phalanx_rows)"
    diverged="$(printf '%s\n' "$rows" | _phalanx_diverged)"
    if [ -z "$(printf '%s' "$rows" | tr -d '[:space:]')" ]; then
      phalanx_new_interactive
      status=$?
      [ "$status" -eq "$PHALANX_BACK" ] && return 0
      return "$status"
    fi

    out="$(
      printf '%s\n' "$rows" | fzf --ansi --delimiter=$'\t' --with-nth=5 \
        --layout=reverse --no-scrollbar --pointer='▌' --marker='▌' \
        --highlight-line --color="$(_phalanx_colors)" \
        --header="$(_phalanx_columns "$diverged")" \
        --footer='enter attach · ctrl-b work · ctrl-o bare · ctrl-n new · ctrl-x kill · ctrl-r reload' \
        --footer-border=line \
        --expect=ctrl-n,ctrl-x,ctrl-b,ctrl-o \
        --bind="ctrl-r:reload($PHALANX_ROOT/bin/phalanx ls --tsv)"
    )" || return 0

    key="$(printf '%s\n' "$out" | sed -n 1p)"
    line="$(printf '%s\n' "$out" | sed -n 2p)"

    if [ "$key" = ctrl-n ]; then
      phalanx_new_interactive
      status=$?
      [ "$status" -eq "$PHALANX_BACK" ] && continue
      return "$status"
    fi

    [ -n "$line" ] || return 0
    target="$(printf '%s' "$line" | cut -f1)"
    kind="$(printf '%s' "$line" | cut -f4)"
    cwd="$(printf '%s' "$line" | cut -f3)"
    pid="$(printf '%s' "$line" | cut -f8)"

    case "$key" in
      ctrl-b|ctrl-o)
        if ! root="$(_phalanx_repo_root "$cwd")"; then
          _phalanx_notice "phalanx: $cwd is not in a git repository"
          continue
        fi
        if [ "$key" = ctrl-o ]; then
          _phalanx_branch_interactive "$root" "$(_phalanx_bare_layout)"
        else
          _phalanx_branch_interactive "$root" ""
        fi
        status=$?
        [ "$status" -eq "$PHALANX_BACK" ] && continue
        return "$status"
        ;;
      ctrl-x)
        _phalanx_kill "$target" "$kind" "$pid" "$cwd"
        continue
        ;;
    esac

    if [ -z "$target" ]; then
      _phalanx_notice \
        "phalanx: this $kind agent runs outside tmux, so there is no pane to attach to"
      continue
    fi

    _phalanx_goto "$target"
    return
  done
}

_phalanx_kill() {
  local target="$1" kind="$2" pid="$3" cwd="$4" session="${1%%:*}" reply root branch

  if [ -n "$target" ]; then
    # The worktree is only phalanx's to remove if phalanx made it.
    case "$cwd" in
      "$PHALANX_HOME"/*)
        root="$(_phalanx_repo_root "$cwd" 2>/dev/null)"
        branch="$(git -C "$cwd" branch --show-current 2>/dev/null)"
        if [ -n "$root" ] && [ -n "$branch" ]; then
          printf '%s: [s]ession only, session and [w]orktree, [a]rchive then remove? [s/w/a/N] ' \
            "$session" >&2
          read -r reply
          case "$reply" in
            s|S) tmux kill-session -t "=$session" ;;
            w|W) phalanx_rm "$branch" "$root" ;;
            a|A) phalanx_archive "$branch" "$root" ;;
            *)   printf 'aborted\n' >&2 ;;
          esac
          return 0
        fi
        ;;
    esac

    printf 'kill tmux session %s? [y/N] ' "$session" >&2
    read -r reply
    case "$reply" in
      y|Y) tmux kill-session -t "=$session" ;;
    esac
    return 0
  fi

  if [ -n "$pid" ]; then
    printf 'phalanx: this agent runs outside tmux, as pid %s\n' "$pid" >&2
    printf 'terminate that process? [y/N] ' >&2
    read -r reply
    case "$reply" in
      y|Y) kill "$pid" 2>/dev/null || printf 'phalanx: could not signal %s\n' "$pid" >&2 ;;
    esac
    return 0
  fi

  if [ "$kind" = background ]; then
    _phalanx_notice \
      'phalanx: this background agent reports no pane and no process, so there is' \
      'phalanx: nothing here to signal. Manage it from claude agents.'
    return 0
  fi

  _phalanx_notice 'phalanx: nothing on this row for phalanx to stop'
}
