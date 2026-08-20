_phalanx_drop_session() {
  tmux has-session -t "=$1" 2>/dev/null || return 0
  tmux kill-session -t "=$1" && printf 'phalanx: killed session %s\n' "$1" >&2
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

  _phalanx_drop_session "$(_phalanx_session_name "$root" "$name")"
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

  _phalanx_remove_worktree "$root" "$dest" || return 1
  _phalanx_drop_session "$(_phalanx_session_name "$root" "$name")"
}

phalanx_archived() {
  local context root
  context="$(_phalanx_cleanup_context "${1:-$PWD}")" || return 1
  root="${context%%	*}"
  git -C "$root" stash list --format='%gd%x09%gs%x09%cr' 2>/dev/null \
    | awk -F'\t' '
        { at = index($2, "phalanx:") }
        at == 0 { next }
        {
          rest = substr($2, at + 8)
          cut = index(rest, "@")
          printf "%-12s %-22s %-22s %s\n", $1,
                 (cut ? substr(rest, 1, cut - 1) : rest),
                 (cut ? substr(rest, cut + 1) : "-"), $3
        }'
}

phalanx_restore() {
  local name="${1:-}" context root repo entry ref branch dest
  [ -n "$name" ] || { printf 'usage: phalanx restore <session>\n' >&2; return 1; }
  context="$(_phalanx_cleanup_context "${2:-$PWD}")" || return 1
  root="${context%%	*}"; repo="${context##*	}"

  entry="$(_phalanx_stash_entry "$root" "$name")"
  ref="${entry%%	*}"
  branch="${entry##*	}"
  [ "$branch" = "HEAD" ] && branch=""

  dest="$(_phalanx_add_worktree "$root" "$repo" "$name" "$branch")" || return 1
  if [ -n "$ref" ]; then
    git -C "$dest" stash pop "$ref" || return 1
    printf 'phalanx: restored %s from %s\n' "$name" "$ref" >&2
  fi

  phalanx_session "$name" worktree "" "" "$root"
}

phalanx_prune() {
  local context root repo base dest name candidates reply
  context="$(_phalanx_cleanup_context "${1:-$PWD}")" || return 1
  root="${context%%	*}"; repo="${context##*	}"
  base="$PHALANX_HOME/worktrees/$repo"

  candidates=""
  if [ -d "$base" ]; then
    for dest in "$base"/*; do
      [ -d "$dest" ] || continue
      name="$(basename "$dest")"
      tmux has-session -t "=$(_phalanx_session_name "$root" "$name")" 2>/dev/null && continue
      candidates="$candidates$name
"
    done
  fi

  if [ -z "$candidates" ]; then
    printf 'phalanx: every worktree here still has a session\n' >&2
    return 0
  fi

  printf 'phalanx: worktrees with no session left:\n' >&2
  printf '%s' "$candidates" | sed 's/^/  /' >&2
  printf 'remove them? [y/N] ' >&2
  read -r reply
  case "$reply" in
    y|Y) ;;
    *) printf 'aborted\n' >&2; return 0 ;;
  esac

  printf '%s' "$candidates" | while IFS= read -r name; do
    [ -n "$name" ] || continue
    phalanx_rm "$name" "$root"
  done
}
