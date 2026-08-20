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
  else
    printf '   state       age  %-18s %-20s %-11s agent\n' repo branch category
  fi
}

# Checked once, from the dispatcher, where the descriptors are still the ones the
# terminal handed us. Inside the pickers every one of them may be a pipe.
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
  done | sort | _phalanx_fzf_pick 'repo > ' 'pick a repo, or type a path · esc goes back'
}

phalanx_list() {
  _phalanx_columns
  phalanx_rows | awk -F'\t' 'NF { print $5 }'
}

_phalanx_existing_names() {
  local base="$PHALANX_HOME/worktrees/$1" dest
  [ -d "$base" ] || return 0
  for dest in "$base"/*; do
    [ -d "$dest" ] && basename "$dest"
  done
}

# One flow: the location is an option on it, not a second kind of session.
_phalanx_session_interactive() {
  local root="$1" location="$2" repo name branch

  repo="$(basename "$root")"
  name="$(_phalanx_existing_names "$repo" \
    | _phalanx_fzf_pick 'session name > ' 'a name for this session, reused or new · esc goes back')"
  [ -n "$name" ] || return "$PHALANX_BACK"

  if [ "$location" = worktree ]; then
    branch="$(
      git -C "$root" for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null \
        | sed -e 's|^origin/||' | grep -v '^HEAD$' | sort -u \
        | _phalanx_fzf_pick 'branch > ' "empty starts a new branch called $name · esc goes back"
    )"
    phalanx_session "$name" worktree "$branch" "" "$root"
  else
    phalanx_session "$name" "" "" "" "$root"
  fi
}

phalanx_worktree_interactive() {
  local root
  if ! root="$(_phalanx_repo_root "${1:-$PWD}")"; then
    printf 'phalanx: not a git repository\n' >&2
    return 1
  fi
  _phalanx_session_interactive "$root" worktree
}

phalanx_main_interactive() {
  local root
  if ! root="$(_phalanx_repo_root "${1:-$PWD}")"; then
    printf 'phalanx: not a git repository\n' >&2
    return 1
  fi
  _phalanx_session_interactive "$root" main
}

phalanx_repo_interactive() {
  local path
  path="$(_phalanx_pick_path)"
  [ -n "$path" ] || return "$PHALANX_BACK"
  case "$path" in "~"*) path="$HOME${path#\~}" ;; esac
  phalanx_worktree_interactive "$path"
}

phalanx_pick() {
  local rows out key line target kind cwd pid root status

  case "$(tmux show-option -gqv @phalanx-compact)" in
    on|1|yes) PHALANX_COMPACT=1; export PHALANX_COMPACT ;;
  esac

  while :; do
    rows="$(phalanx_rows)"
    if [ -z "$(printf '%s' "$rows" | tr -d '[:space:]')" ]; then
      phalanx_repo_interactive
      status=$?
      [ "$status" -eq "$PHALANX_BACK" ] && return 0
      return "$status"
    fi

    out="$(
      printf '%s\n' "$rows" | fzf --ansi --delimiter=$'\t' --with-nth=5 \
        --layout=reverse --no-scrollbar --pointer='▌' --marker='▌' \
        --highlight-line --color="$(_phalanx_colors)" \
        --header="$(_phalanx_columns)" \
        --footer='enter attach · ctrl-b worktree · ctrl-e main · ctrl-n repo · ctrl-x remove · ctrl-r reload' \
        --footer-border=line \
        --expect=ctrl-n,ctrl-x,ctrl-b,ctrl-e \
        --bind="ctrl-r:reload($PHALANX_ROOT/bin/phalanx ls --tsv)"
    )" || return 0

    key="$(printf '%s\n' "$out" | sed -n 1p)"
    line="$(printf '%s\n' "$out" | sed -n 2p)"

    if [ "$key" = ctrl-n ]; then
      phalanx_repo_interactive
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
      ctrl-b|ctrl-e)
        if ! root="$(_phalanx_repo_root "$cwd")"; then
          _phalanx_notice "phalanx: $cwd is not in a git repository"
          continue
        fi
        if [ "$key" = ctrl-b ]; then
          _phalanx_session_interactive "$root" worktree
        else
          _phalanx_session_interactive "$root" main
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
  local target="$1" kind="$2" pid="$3" cwd="$4" session="${1%%:*}" reply root name

  if [ -n "$target" ]; then
    # The worktree is only phalanx's to remove if phalanx made it.
    case "$cwd" in
      "$PHALANX_HOME"/*)
        root="$(_phalanx_repo_root "$cwd" 2>/dev/null)"
        name="${session#*/}"
        if [ -n "$root" ] && [ "$name" != "$session" ]; then
          printf '%s: [s]ession only, session and [w]orktree, [a]rchive then remove? [s/w/a/N] ' \
            "$session" >&2
          read -r reply
          case "$reply" in
            s|S) tmux kill-session -t "=$session" ;;
            w|W) phalanx_rm "$name" "$root" ;;
            a|A) phalanx_archive "$name" "$root" ;;
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
