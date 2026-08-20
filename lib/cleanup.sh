# Found by path rather than by name, because a session's name need not match the
# worktree it runs in, and more than one can run in the same one.
_phalanx_sessions_in() {
  tmux list-sessions -F '#{session_name}	#{session_path}' 2>/dev/null \
    | awk -F'\t' -v dir="$1" '$2 == dir || index($2, dir "/") == 1 { print $1 }'
}

_phalanx_drop_sessions_in() {
  local session
  _phalanx_sessions_in "$1" | while IFS= read -r session; do
    [ -n "$session" ] || continue
    tmux kill-session -t "=$session" && printf 'phalanx: killed session %s\n' "$session" >&2
  done
}

# Never --force: git refuses a worktree holding modified or untracked files, and
# that refusal is the only thing standing between you and the .env this tool put
# there itself.
_phalanx_remove_worktree() {
  local root="$1" worktree="$2"
  if [ "$worktree" = "$root" ]; then
    printf 'phalanx: that is the main checkout, leaving it alone\n' >&2
    return 1
  fi
  git -C "$root" worktree remove "$worktree" || return 1
  printf 'phalanx: removed worktree %s\n' "$worktree" >&2
}

_phalanx_forget_worktree() {
  git -C "$1" config --remove-section "phalanx.$2" 2>/dev/null || true
}

_phalanx_archived_branch() {
  git -C "$1" config --get "phalanx.$2.archived" 2>/dev/null
}

_phalanx_stash_entry() {
  git -C "$1" stash list --format='%gd%x09%gs' 2>/dev/null \
    | awk -F'\t' -v tag="phalanx:$2@" '
        { at = index($2, tag) }
        at > 0 { print $1 "\t" substr($2, at + length(tag)); exit }'
}

_phalanx_cleanup_context() {
  local root
  root="$(_phalanx_repo_root "${1:-$PWD}")" || {
    printf 'phalanx: not a git repository\n' >&2
    return 1
  }
  printf '%s\t%s\n' "$root" "$(basename "$root")"
}

phalanx_rm() {
  local name="${1:-}" context root repo dest
  [ -n "$name" ] || { printf 'usage: phalanx rm <session>\n' >&2; return 1; }
  context="$(_phalanx_cleanup_context "${2:-$PWD}")" || return 1
  root="${context%%	*}"; repo="${context##*	}"
  dest="$(_phalanx_session_worktree "$repo" "$name")"

  if [ -d "$dest" ] && ! _phalanx_remove_worktree "$root" "$dest"; then
    printf 'phalanx: nothing was lost. Commit it, or keep it with:\n' >&2
    printf 'phalanx:   phalanx archive %s\n' "$name" >&2
    return 1
  fi

  _phalanx_drop_sessions_in "$dest"
  _phalanx_forget_worktree "$root" "$name"
}

phalanx_archive() {
  local name="${1:-}" context root repo dest branch
  [ -n "$name" ] || { printf 'usage: phalanx archive <session>\n' >&2; return 1; }
  context="$(_phalanx_cleanup_context "${2:-$PWD}")" || return 1
  root="${context%%	*}"; repo="${context##*	}"
  dest="$(_phalanx_session_worktree "$repo" "$name")"

  if [ ! -d "$dest" ]; then
    printf 'phalanx: %s has no worktree to archive\n' "$name" >&2
    return 1
  fi

  branch="$(git -C "$dest" branch --show-current 2>/dev/null)"
  if [ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]; then
    git -C "$dest" stash push -u -m "phalanx:$name@${branch:-HEAD}" >/dev/null || return 1
    printf 'phalanx: stashed the working tree as phalanx:%s@%s\n' "$name" "${branch:-HEAD}" >&2
  fi

  # Recorded even with nothing to stash, so a clean worktree is still listed and
  # still comes back on the branch it was on.
  git -C "$root" config "phalanx.$name.archived" "${branch:-HEAD}"

  _phalanx_remove_worktree "$root" "$dest" || return 1
  _phalanx_drop_sessions_in "$dest"
}

phalanx_archived() {
  local context root
  context="$(_phalanx_cleanup_context "${1:-$PWD}")" || return 1
  root="${context%%	*}"

  printf '%-24s %-24s %s\n' session branch stash
  git -C "$root" config --get-regexp '^phalanx\..*\.archived$' 2>/dev/null \
    | while read -r key branch; do
        name="${key#phalanx.}"
        name="${name%.archived}"
        stash="$(_phalanx_stash_entry "$root" "$name")"
        printf '%-24s %-24s %s\n' "$name" "$branch" "${stash%%	*}"
      done
}

phalanx_restore() {
  local name="${1:-}" context root repo entry ref branch dest
  [ -n "$name" ] || { printf 'usage: phalanx restore <session>\n' >&2; return 1; }
  context="$(_phalanx_cleanup_context "${2:-$PWD}")" || return 1
  root="${context%%	*}"; repo="${context##*	}"

  entry="$(_phalanx_stash_entry "$root" "$name")"
  ref="${entry%%	*}"

  branch="$(_phalanx_archived_branch "$root" "$name")"
  [ -n "$branch" ] || branch="${entry##*	}"
  [ "$branch" = HEAD ] && branch=""

  dest="$(_phalanx_add_worktree "$root" "$repo" "$name" "$branch")" || return 1
  if [ -n "$ref" ]; then
    git -C "$dest" stash pop "$ref" || return 1
    printf 'phalanx: restored %s from %s\n' "$name" "$ref" >&2
  fi
  git -C "$root" config --unset "phalanx.$name.archived" 2>/dev/null || true

  phalanx_session "$name" worktree "" "" "$root"
}

phalanx_prune() {
  local context root repo base dest name candidates
  context="$(_phalanx_cleanup_context "${1:-$PWD}")" || return 1
  root="${context%%	*}"; repo="${context##*	}"
  base="$PHALANX_HOME/worktrees/$repo"

  candidates=""
  if [ -d "$base" ]; then
    for dest in "$base"/*; do
      [ -d "$dest" ] || continue
      name="$(basename "$dest")"
      [ -n "$(_phalanx_sessions_in "$dest")" ] && continue
      candidates="$candidates$name
"
    done
  fi

  if [ -z "$candidates" ]; then
    printf 'phalanx: every worktree here still has a session\n' >&2
    return 0
  fi

  _phalanx_confirm \
    'Worktrees with no session left:' \
    "$(printf '%s' "$candidates" | sed 's/^/  /')" \
    || return 0

  printf '%s' "$candidates" | while IFS= read -r name; do
    [ -n "$name" ] || continue
    phalanx_rm "$name" "$root"
  done
}
