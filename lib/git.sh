PHALANX_HOME="${PHALANX_HOME:-$HOME/.phalanx}"

_phalanx_repo_root() {
  local dir="${1:-$PWD}" common
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  dirname "$common"
}

_phalanx_worktree_holding() {
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | awk -v want="branch refs/heads/$2" '/^worktree /{ w=$2 } $0==want { print w; exit }'
}

_phalanx_worktree_path() {
  printf '%s/worktrees/%s/%s\n' "$PHALANX_HOME" "$1" "$2"
}

_phalanx_repo_config() {
  local root="$1" config="${XDG_CONFIG_HOME:-$HOME/.config}/phalanx/repos/$(basename "$1")"
  if [ -f "$root/.phalanx.conf" ]; then
    printf '%s\n' "$root/.phalanx.conf"
  elif [ -f "$config" ]; then
    printf '%s\n' "$config"
  fi
}

_phalanx_config_values() {
  [ -n "$1" ] && [ -f "$1" ] || return 0
  awk -v key="$2" '
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    {
      n = split($0, a, /[ \t]+/)
      if (a[1] != key || n < 2) next
      v = a[2]
      for (i = 3; i <= n; i++) v = v " " a[i]
      print v
    }' "$1"
}

_phalanx_provision() {
  local root="$1" dest="$2" config item
  config="$(_phalanx_repo_config "$root")"
  [ -n "$config" ] || return 0

  _phalanx_config_values "$config" link | while IFS= read -r item; do
    [ -n "$item" ] && [ -e "$root/$item" ] && [ ! -e "$dest/$item" ] || continue
    mkdir -p "$(dirname "$dest/$item")"
    ln -s "$root/$item" "$dest/$item" && printf 'phalanx: linked %s\n' "$item" >&2
  done

  _phalanx_config_values "$config" copy | while IFS= read -r item; do
    [ -n "$item" ] && [ -e "$root/$item" ] && [ ! -e "$dest/$item" ] || continue
    mkdir -p "$(dirname "$dest/$item")"
    cp -R "$root/$item" "$dest/$item" && printf 'phalanx: copied %s\n' "$item" >&2
  done

  _phalanx_config_values "$config" postcreate | while IFS= read -r item; do
    [ -n "$item" ] || continue
    printf 'phalanx: postcreate: %s\n' "$item" >&2
    (cd "$dest" && eval "$item") >&2
  done
}

_phalanx_default_branch() {
  local root="$1" ref candidate
  ref="$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return
  fi
  for candidate in main master; do
    if git -C "$root" show-ref --verify --quiet "refs/heads/$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done
}

# The main worktree holds the default branch and worktrees hold everything else.
# Letting the main one drift off the default branch locks that branch out of a
# worktree of its own, and git then refuses to create one.
_phalanx_ensure_worktree() {
  local root="$1" branch="$2" existing default dest

  existing="$(_phalanx_worktree_holding "$root" "$branch")"
  default="$(_phalanx_default_branch "$root")"

  if [ "$branch" = "$default" ]; then
    if [ "$existing" = "$root" ]; then
      printf '%s\n' "$root"
      return
    fi
    printf 'phalanx: %s belongs in the main worktree\n' "$branch" >&2
    printf 'phalanx:   %s\n' "$root" >&2
    printf 'phalanx: it is on %s instead, so put it back first:\n' \
      "$(git -C "$root" branch --show-current 2>/dev/null)" >&2
    printf 'phalanx:   git -C %s switch %s\n' "$root" "$branch" >&2
    return 1
  fi

  if [ "$existing" = "$root" ]; then
    printf 'phalanx: %s is checked out in the main worktree\n' "$branch" >&2
    printf 'phalanx:   %s\n' "$root" >&2
    printf 'phalanx: put that back on %s first, then try again:\n' "$default" >&2
    printf 'phalanx:   git -C %s switch %s\n' "$root" "$default" >&2
    return 1
  fi

  if [ -n "$existing" ]; then
    printf '%s\n' "$existing"
    return
  fi

  dest="$(_phalanx_worktree_path "$(basename "$root")" "$branch")"
  mkdir -p "$(dirname "$dest")"

  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$root" worktree add "$dest" "$branch" >/dev/null || return 1
  elif git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$root" worktree add --track -b "$branch" "$dest" "origin/$branch" >/dev/null || return 1
  else
    git -C "$root" worktree add -b "$branch" "$dest" >/dev/null || return 1
  fi

  _phalanx_provision "$root" "$dest"
  printf '%s\n' "$dest"
}
