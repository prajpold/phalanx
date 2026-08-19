_phalanx_branch_session_name() {
  _phalanx_sanitize "$(basename "$1")/$2"
}

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
    printf 'phalanx: that is the main worktree, leaving it alone\n' >&2
    return 1
  fi
  git -C "$root" worktree remove "$worktree" || return 1
  printf 'phalanx: removed worktree %s\n' "$worktree" >&2
}

_phalanx_stash_ref() {
  git -C "$1" stash list --format='%gd%x09%gs' 2>/dev/null \
    | awk -F'\t' -v want="phalanx:$2" '
        substr($2, length($2) - length(want) + 1) == want { print $1; exit }'
}

phalanx_rm() {
  local branch="${1:-}" root worktree
  [ -n "$branch" ] || { printf 'usage: phalanx rm <branch>\n' >&2; return 1; }
  root="$(_phalanx_repo_root "${2:-$PWD}")" || {
    printf 'phalanx: not a git repository\n' >&2
    return 1
  }

  worktree="$(_phalanx_worktree_holding "$root" "$branch")"
  if [ -n "$worktree" ] && ! _phalanx_remove_worktree "$root" "$worktree"; then
    printf 'phalanx: nothing was lost. Commit it, or keep it with:\n' >&2
    printf 'phalanx:   phalanx archive %s\n' "$branch" >&2
    return 1
  fi

  _phalanx_drop_session "$(_phalanx_branch_session_name "$root" "$branch")"
  printf 'phalanx: branch %s is untouched\n' "$branch" >&2
}

phalanx_archive() {
  local branch="${1:-}" root worktree
  [ -n "$branch" ] || { printf 'usage: phalanx archive <branch>\n' >&2; return 1; }
  root="$(_phalanx_repo_root "${2:-$PWD}")" || {
    printf 'phalanx: not a git repository\n' >&2
    return 1
  }

  worktree="$(_phalanx_worktree_holding "$root" "$branch")"
  if [ -z "$worktree" ]; then
    printf 'phalanx: %s has no worktree to archive\n' "$branch" >&2
    return 1
  fi

  if [ -n "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]; then
    git -C "$worktree" stash push -u -m "phalanx:$branch" >/dev/null || return 1
    printf 'phalanx: stashed the working tree as phalanx:%s\n' "$branch" >&2
  fi

  _phalanx_remove_worktree "$root" "$worktree" || return 1
  _phalanx_drop_session "$(_phalanx_branch_session_name "$root" "$branch")"
}

phalanx_archived() {
  local root
  root="$(_phalanx_repo_root "${1:-$PWD}")" || {
    printf 'phalanx: not a git repository\n' >&2
    return 1
  }
  git -C "$root" stash list --format='%gd%x09%gs%x09%cr' 2>/dev/null \
    | awk -F'\t' '
        { at = index($2, "phalanx:") }
        at > 0 { printf "%-12s %-30s %s\n", $1, substr($2, at + 8), $3 }'
}

phalanx_restore() {
  local branch="${1:-}" root worktree ref
  [ -n "$branch" ] || { printf 'usage: phalanx restore <branch>\n' >&2; return 1; }
  root="$(_phalanx_repo_root "${2:-$PWD}")" || {
    printf 'phalanx: not a git repository\n' >&2
    return 1
  }

  worktree="$(_phalanx_ensure_worktree "$root" "$branch")" || return 1
  ref="$(_phalanx_stash_ref "$root" "$branch")"
  if [ -n "$ref" ]; then
    git -C "$worktree" stash pop "$ref" || return 1
    printf 'phalanx: restored %s from %s\n' "$branch" "$ref" >&2
  fi

  phalanx_work "$branch" "" "$root"
}

phalanx_prune() {
  local root default branch worktree candidates reply
  root="$(_phalanx_repo_root "${1:-$PWD}")" || {
    printf 'phalanx: not a git repository\n' >&2
    return 1
  }
  default="$(_phalanx_default_branch "$root")"

  candidates=""
  for branch in $(git -C "$root" branch --merged "$default" --format='%(refname:short)' 2>/dev/null); do
    [ "$branch" = "$default" ] && continue
    worktree="$(_phalanx_worktree_holding "$root" "$branch")"
    [ -n "$worktree" ] || continue
    # Only worktrees phalanx made, so a checkout you set up by hand is never touched.
    case "$worktree" in
      "$PHALANX_HOME"/*) candidates="$candidates$branch" ;;
      *) continue ;;
    esac
    candidates="$candidates
"
  done

  if [ -z "$candidates" ]; then
    printf 'phalanx: no worktrees for branches already merged into %s\n' "$default" >&2
    return 0
  fi

  printf 'phalanx: merged into %s, so their worktrees can go:\n' "$default" >&2
  printf '%s' "$candidates" | sed 's/^/  /' >&2
  printf 'remove them? [y/N] ' >&2
  read -r reply
  case "$reply" in
    y|Y) ;;
    *) printf 'aborted\n' >&2; return 0 ;;
  esac

  printf '%s' "$candidates" | while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    phalanx_rm "$branch" "$root"
  done
}
