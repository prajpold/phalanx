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
