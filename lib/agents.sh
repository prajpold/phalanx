_phalanx_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

_phalanx_agents_tsv() {
  claude agents --json 2>/dev/null | jq -r '
    (if type == "array" then . else [] end)[]
    | ["AGENT",
       (.kind // "interactive"),
       (.pid // ""),
       (.sessionId // ""),
       (.status // .state // "unknown"),
       (.name // ""),
       (.cwd // ""),
       (.startedAt // "")]
    | @tsv' 2>/dev/null
}

# Transcript mtime is the only available proxy for last activity; startedAt in
# `claude agents --json` is the session start, not the last turn.
# Pre-split with awk: read collapses runs of tabs because tab is IFS whitespace,
# and background agents carry no pid, so the empty field would shift the rest.
_phalanx_mtimes() {
  local sid cwd slug file
  awk -F'\t' '$4 != "" { print $4 "\t" $7 }' \
  | while IFS=$'\t' read -r sid cwd; do
    [ -n "$sid" ] || continue
    slug="$(printf '%s' "$cwd" | tr '/.' '-')"
    file="$HOME/.claude/projects/$slug/$sid.jsonl"
    if [ ! -f "$file" ]; then
      file=""
      for candidate in "$HOME"/.claude/projects/*/"$sid".jsonl; do
        [ -f "$candidate" ] || continue
        file="$candidate"
        break
      done
    fi
    [ -n "$file" ] || continue
    printf 'MTIME\t%s\t%s\n' "$sid" "$(_phalanx_mtime "$file")"
  done
}

# The branch is read fresh every time: a session does not own one, and switching
# inside a worktree has to show up on the next refresh.
_phalanx_branches() {
  local dir branch
  while IFS= read -r dir; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    branch="$(git -C "$dir" branch --show-current 2>/dev/null)"
    [ -n "$branch" ] && printf 'BRANCH\t%s\t%s\n' "$dir" "$branch"
  done
}

phalanx_rows() {
  local agents tab=$'\t'
  agents="$(_phalanx_agents_tsv)"
  {
    tmux list-panes -a -F "PANE${tab}#{pane_tty}${tab}#{session_name}:#{window_index}.#{pane_index}${tab}#{session_id}" 2>/dev/null || true
    tmux list-sessions -F "SESS${tab}#{session_name}${tab}#{@phalanx-location}${tab}#{@phalanx-repo}${tab}#{session_path}${tab}#{session_id}" 2>/dev/null || true
    ps -eo pid=,tty= 2>/dev/null | awk -v OFS="$tab" '{ print "PS", $1, $2 }'
    printf '%s\n' "$agents" | _phalanx_mtimes
    {
      printf '%s\n' "$agents" | cut -f7
      tmux list-sessions -F '#{session_path}' 2>/dev/null || true
    } | sort -u | _phalanx_branches
    printf '%s\n' "$agents"
  } | awk -F"$tab" -v OFS="$tab" -v now="$(date +%s)" -v compact="${PHALANX_COMPACT:-}" -f "$PHALANX_ROOT/lib/rows.awk" \
    | sort -t"$tab" -k7,7 -k6,6 -k3,3
}
