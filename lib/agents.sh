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
       (.cwd // "")]
    | @tsv' 2>/dev/null
}

# Transcript mtime is the only available proxy for last activity; startedAt in
# `claude agents --json` is the session start, not the last turn.
_phalanx_mtimes() {
  local sid cwd slug file
  while IFS=$'\t' read -r _ _ _ sid _ _ cwd; do
    [ -n "$sid" ] || continue
    slug="$(printf '%s' "$cwd" | tr '/.' '-')"
    file="$HOME/.claude/projects/$slug/$sid.jsonl"
    if [ ! -f "$file" ]; then
      file="$(ls -1 "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)"
    fi
    [ -n "$file" ] && [ -f "$file" ] || continue
    printf 'MTIME\t%s\t%s\n' "$sid" "$(_phalanx_mtime "$file")"
  done
}

phalanx_rows() {
  local agents tab=$'\t'
  agents="$(_phalanx_agents_tsv)"
  {
    tmux list-panes -a -F "PANE${tab}#{pane_tty}${tab}#{session_name}:#{window_index}.#{pane_index}" 2>/dev/null || true
    tmux list-sessions -F "SESS${tab}#{session_name}${tab}#{@phalanx-role}${tab}#{@phalanx-branch}${tab}#{@phalanx-repo}${tab}#{session_path}" 2>/dev/null || true
    ps -eo pid=,tty= 2>/dev/null | awk -v OFS="$tab" '{ print "PS", $1, $2 }'
    printf '%s\n' "$agents" | _phalanx_mtimes
    printf '%s\n' "$agents"
  } | awk -F"$tab" -v OFS="$tab" -v now="$(date +%s)" -f "$PHALANX_ROOT/lib/rows.awk" \
    | sort -t"$tab" -k6,6 -k3,3
}
