#!/usr/bin/env bash
set -uo pipefail

REPO="${PHALANX_REPO:-https://github.com/prajpold/phalanx.git}"
PREFIX="${PHALANX_PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/phalanx}"
BIN_DIR="${PHALANX_BIN_DIR:-$HOME/.local/bin}"

MARK_BEGIN='# phalanx begin'
MARK_END='# phalanx end'

die() { printf 'phalanx: %s\n' "$1" >&2; exit 1; }
note() { printf '%s\n' "$1"; }

usage() {
  cat <<'EOF'
phalanx installer

  install.sh [version]        install or update, latest tag by default
  install.sh v0.3.0           pin a tag
  install.sh master           track a branch tip

  --no-path                   leave your shell config alone
  --no-tmux                   leave your tmux config alone

piped from curl, pass arguments after -s --:
  curl -fsSL .../install.sh | bash -s -- v0.3.0

env: PHALANX_REPO, PHALANX_PREFIX (default ~/.local/share/phalanx),
     PHALANX_BIN_DIR (default ~/.local/bin)
EOF
}

version=""
edit_path=1
edit_tmux=1

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-path) edit_path=""; shift ;;
    --no-tmux) edit_tmux=""; shift ;;
    -*) usage >&2; exit 1 ;;
    *)
      [ -z "$version" ] || { usage >&2; exit 1; }
      version="$1"; shift
      ;;
  esac
done

# Through a symlink rather than over it. A config linked out of a dotfiles repo
# belongs to that repo, and swapping the link for a plain file means the next run
# of whatever manages it moves our file aside and relinks — taking the block with
# it, silently, weeks later.
write_through() {
  local tmp="$1" file="$2"
  if [ -L "$file" ]; then
    cat "$tmp" > "$file" && rm -f "$tmp"
  else
    mv "$tmp" "$file"
  fi
}

# Rewrites its own block rather than appending, so installing twice leaves one
# entry and a moved PREFIX does not leave the old path behind.
write_block() {
  local file="$1" body="$2" tmp
  mkdir -p "$(dirname "$file")" || return 1
  tmp="$file.phalanx.$$"

  if [ -f "$file" ]; then
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
      $0 == b { skip = 1 }
      !skip   { print }
      $0 == e { skip = 0 }
    ' "$file" > "$tmp" || return 1
  else
    : > "$tmp" || return 1
  fi

  printf '\n%s\n%s\n%s\n' "$MARK_BEGIN" "$body" "$MARK_END" >> "$tmp" || return 1
  write_through "$tmp" "$file"
}

# Where an older install put its block is not where this one writes, and two
# blocks would bind the keys twice. Reports whether there was one to drop.
drop_block() {
  local file="$1" tmp
  [ -f "$file" ] || return 1
  grep -qF "$MARK_BEGIN" "$file" || return 1
  tmp="$file.phalanx.$$"

  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip = 1 }
    !skip   { keep[++n] = $0 }
    $0 == e { skip = 0 }
    END {
      while (n > 0 && keep[n] == "") n--
      for (i = 1; i <= n; i++) print keep[i]
    }
  ' "$file" > "$tmp" || return 1
  write_through "$tmp" "$file"
}

# A hand-rolled run-shell is not ours to move: appending a second one would bind
# the keys twice, and the options set around theirs would apply to neither.
has_unmanaged() {
  local file="$1" pattern="$2"
  [ -f "$file" ] || return 1
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip = 1 }
    !skip   { print }
    $0 == e { skip = 0 }
  ' "$file" | grep -q "$pattern"
}

shell_config() {
  case "$(basename "${SHELL:-}")" in
    zsh)  printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    fish) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ;;
    bash)
      if [ -f "$HOME/.bash_profile" ]; then
        printf '%s\n' "$HOME/.bash_profile"
      elif [ -f "$HOME/.bashrc" ]; then
        printf '%s\n' "$HOME/.bashrc"
      else
        printf '%s\n' "$HOME/.bash_profile"
      fi
      ;;
    *) return 1 ;;
  esac
}

path_body() {
  if [ "$(basename "${SHELL:-}")" = fish ]; then
    printf 'fish_add_path %s\n' "$BIN_DIR"
  else
    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
  fi
}

# tmux reads ~/.tmux.conf and the XDG file both, in that order, so this is one we
# can own outright. A config that stow, chezmoi or a dotfiles repo manages is left
# alone, which keeps the popup keys out of a repo that has no business knowing
# about phalanx.
tmux_config() {
  printf '%s\n' "$HOME/.tmux.conf"
}

tmux_managed_config() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
}

command -v git >/dev/null || die 'git is required'

if [ -d "$PREFIX/.git" ]; then
  git -C "$PREFIX" remote set-url origin "$REPO"
  git -C "$PREFIX" fetch --quiet --tags --prune origin || die "cannot reach $REPO"
else
  mkdir -p "$(dirname "$PREFIX")" || die "cannot create $(dirname "$PREFIX")"
  git clone --quiet "$REPO" "$PREFIX" || die "cannot clone $REPO"
fi

if [ -z "$version" ]; then
  version="$(git -C "$PREFIX" tag --list --sort=-v:refname | head -1)"
  [ -n "$version" ] || die 'no tags to install from, pass a branch or a commit'
fi

for candidate in "refs/tags/$version" "refs/remotes/origin/$version" "$version"; do
  if commit="$(git -C "$PREFIX" rev-parse --quiet --verify "$candidate^{commit}")"; then
    break
  fi
  commit=""
done
[ -n "$commit" ] || die "no such version: $version"

git -C "$PREFIX" checkout --quiet --detach "$commit" || die "cannot check out $version"

mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"
ln -sfn "$PREFIX/bin/phalanx" "$BIN_DIR/phalanx"

note "phalanx $("$PREFIX/bin/phalanx" --version) installed at $PREFIX"
note "  $BIN_DIR/phalanx -> $PREFIX/bin/phalanx"

on_path=""
case ":$PATH:" in
  *":$BIN_DIR:"*) on_path=1 ;;
esac

if [ -n "$edit_path" ] && [ -z "$on_path" ]; then
  if config="$(shell_config)"; then
    if write_block "$config" "$(path_body)"; then
      note "  put $BIN_DIR on your PATH in $config"
      note "  open a new shell, or source it, to pick that up"
    else
      note "  could not write $config, add $BIN_DIR to your PATH yourself"
    fi
  else
    note "  unknown shell ${SHELL:-}, add $BIN_DIR to your PATH yourself"
  fi
elif [ -z "$on_path" ]; then
  note "  $BIN_DIR is not on your PATH"
fi

if [ -n "$edit_tmux" ]; then
  conf="$(tmux_config)"
  managed="$(tmux_managed_config)"
  if has_unmanaged "$conf" 'phalanx\.tmux' || has_unmanaged "$managed" 'phalanx\.tmux'; then
    note '  your tmux config already runs phalanx itself, leaving it alone'
    note "  point that run-shell at $PREFIX/phalanx.tmux to use this copy"
  elif write_block "$conf" "run-shell $PREFIX/phalanx.tmux"; then
    note "  bound the popup keys in $conf"
    drop_block "$managed" && note "  dropped the block an older install left in $managed"
    if command -v tmux >/dev/null && tmux list-sessions >/dev/null 2>&1; then
      tmux source-file "$conf" >/dev/null 2>&1 \
        && note '  reloaded your running tmux, the keys work now'
    fi
  else
    note "  could not write $conf, add: run-shell $PREFIX/phalanx.tmux"
  fi
else
  note "  add to your tmux.conf: run-shell $PREFIX/phalanx.tmux"
fi

missing=""
for tool in tmux jq fzf; do
  command -v "$tool" >/dev/null || missing="$missing $tool"
done

if [ -n "$missing" ]; then
  note ''
  note "still needed:$missing"
  note "  brew install$missing"
fi
