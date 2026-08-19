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

phalanx_envs() {
  local root
  root="$(_phalanx_repo_root "${1:-$PWD}")" || return 1
  _phalanx_config_values "$(_phalanx_repo_config "$root")" env
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

_phalanx_ensure_worktree() {
  local root="$1" branch="$2" existing dest

  existing="$(_phalanx_worktree_holding "$root" "$branch")"
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

# A direct refspec push succeeds even when the branch is checked out in another
# worktree, which silently leaves that worktree behind origin. Refuse instead.
phalanx_push() {
  local branch="${1:-}" root holder
  [ -n "$branch" ] || { printf 'usage: phalanx push <env-branch>\n' >&2; return 1; }

  root="$(_phalanx_repo_root)" || { printf 'phalanx: not a git repository\n' >&2; return 1; }
  holder="$(_phalanx_worktree_holding "$root" "$branch")"
  if [ -n "$holder" ]; then
    printf 'phalanx: %s is checked out at %s\n' "$branch" "$holder" >&2
    printf 'phalanx: merge there instead — a direct push would leave it stale\n' >&2
    return 1
  fi

  git fetch origin || return 1
  git push origin "HEAD:refs/heads/$branch"
}
