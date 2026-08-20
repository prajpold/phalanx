# Returned by a picker the user backed out of, so the caller redraws instead of
# treating it as a finished action.
PHALANX_BACK=2

# Every prompt goes through fzf so it carries the same frame, colours and keys as
# the list. Falls back to a plain read where no terminal is attached, which keeps
# the command-line paths scriptable.
_phalanx_menu() {
  local prompt="$1" header="$2"
  shift 2
  printf '%s\n' "$@" \
    | fzf --prompt="$prompt > " --header="$header" --header-first \
          --layout=reverse --no-scrollbar --pointer='▌' --highlight-line \
          --color="$(_phalanx_colors)" --footer-border=line \
          --footer='enter picks · esc goes back' 2>/dev/null
}

_phalanx_interactive() {
  [ -t 0 ] || [ -t 2 ]
}

_phalanx_notice() {
  if ! _phalanx_interactive; then
    printf '%s\n' "$@" >&2
    return 0
  fi
  _phalanx_menu back "$(printf '%s\n' "$@")" 'back to the list' >/dev/null
}

_phalanx_confirm() {
  local reply
  if ! _phalanx_interactive; then
    printf '%s\n' "$@" >&2
    printf 'continue? [y/N] ' >&2
    read -r reply
    case "$reply" in y|Y) return 0 ;; *) return 1 ;; esac
  fi
  [ "$(_phalanx_menu confirm "$(printf '%s\n' "$@")" no yes)" = yes ]
}

_phalanx_current_session_id() {
  local id
  id="$(tmux display-message -p '#{session_id}' 2>/dev/null)"
  if [ -n "$id" ]; then
    printf '%s\n' "$id"
    return
  fi
  tmux list-clients -F '#{session_id}' 2>/dev/null | head -1
}

_phalanx_next_session_id() {
  tmux list-sessions -F '#{session_activity} #{session_id}' 2>/dev/null \
    | sort -rn | awk -v cur="$1" '$2 != cur { print $2; exit }'
}

# Killing the session you are attached to leaves the client with nowhere to go,
# so move it first, and refuse when there is nowhere to move it to.
_phalanx_leave_session() {
  local id="$1" current next
  current="$(_phalanx_current_session_id)"
  [ -n "$id" ] && [ "$id" = "$current" ] || return 0

  next="$(_phalanx_next_session_id "$id")"
  if [ -z "$next" ]; then
    _phalanx_notice \
      'This is the session you are in, and the only one left.' \
      'Removing it would drop you out of tmux, so it is left alone.' \
      'Detach first, or remove it from outside.'
    return 1
  fi

  _phalanx_confirm \
    'This is the session you are in.' \
    "You will be moved to $(tmux display-message -p -t "$next" '#{session_name}' 2>/dev/null) first." \
    || return 1

  tmux switch-client -t "$next"
}

_phalanx_kill_session_id() {
  _phalanx_leave_session "$1" || return 1
  tmux kill-session -t "$1"
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
    printf '     age  cat  %-28s %-10s agent\n' 'repo/session' branch
  else
    printf '   state       age  %-20s %-20s %-14s %-11s agent\n' repo session branch category
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
    phalanx_session "$name" "$name" "$branch" "" "$root"
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
        _phalanx_kill "$target" "$kind" "$pid" "$cwd" "$(printf '%s' "$line" | cut -f9)"
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
  local target="$1" kind="$2" pid="$3" cwd="$4" sessionid="$5"
  local session="${1%%:*}" choice root name

  if [ -n "$target" ]; then
    case "$cwd" in
      # The worktree is only phalanx's to remove if phalanx made it.
      "$PHALANX_HOME"/*)
        root="$(_phalanx_repo_root "$cwd" 2>/dev/null)"
        name="$(basename "$cwd")"
        if [ -n "$root" ]; then
          choice="$(_phalanx_menu remove "$(printf '%s\n%s' "$session" "$cwd")" \
            'session only' 'session and worktree' 'archive, then remove')"
          case "$choice" in
            'session only')         _phalanx_kill_session_id "$sessionid" ;;
            'session and worktree') _phalanx_leave_session "$sessionid" && phalanx_rm "$name" "$root" ;;
            'archive, then remove') _phalanx_leave_session "$sessionid" && phalanx_archive "$name" "$root" ;;
          esac
          return 0
        fi
        ;;
    esac

    if _phalanx_confirm "Kill the tmux session $session?"; then
      _phalanx_kill_session_id "$sessionid"
    fi
    return 0
  fi

  if [ -n "$pid" ]; then
    if _phalanx_confirm \
        "This agent runs outside tmux, as pid $pid." \
        'Terminating it stops the agent.'; then
      kill "$pid" 2>/dev/null || _phalanx_notice "Could not signal $pid."
    fi
    return 0
  fi

  if [ "$kind" = background ]; then
    _phalanx_notice \
      'This background agent reports no pane and no process, so there is' \
      'nothing here to signal. Manage it from claude agents.'
    return 0
  fi

  _phalanx_notice 'Nothing on this row for phalanx to stop.'
}
