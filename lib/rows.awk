function icon(s) {
  if (s == "busy" || s == "running") return "●"
  if (s == "idle") return "○"
  if (s == "blocked" || s == "waiting") return "◆"
  if (s == "error") return "✗"
  if (s == "ops") return "⚙"
  return "▪"
}

function color(s) {
  if (s == "busy" || s == "running") return "\033[32m"
  if (s == "blocked" || s == "waiting") return "\033[33m"
  if (s == "error") return "\033[31m"
  if (s == "ops") return "\033[35m"
  return "\033[2m"
}

function ago(ts,   d) {
  if (ts == "") return "-"
  d = now - ts
  if (d < 0) d = 0
  if (d < 60) return d "s"
  if (d < 3600) return int(d / 60) "m"
  if (d < 86400) return int(d / 3600) "h"
  return int(d / 86400) "d"
}

function basename(p,   n, a) {
  n = split(p, a, "/")
  return n ? a[n] : p
}

function emit(target, sid, cwd, kind, status, name, repo, br,   st, where, disp) {
  if (repo == "") repo = basename(cwd)
  st = color(status) sprintf("%s %-8s", icon(status), status) "\033[0m"

  where = target
  if (where == "") where = (kind == "background") ? "no pane (bg)" : "no pane"

  disp = sprintf("%s %4s  %-16s %-16s %-22s %s",
                 st, ago(mtime[sid]), repo, (br == "" ? "-" : br), where, name)
  if (target == "") disp = "\033[2m" disp "\033[0m"
  print target, sid, cwd, kind, disp, repo
}

$1 == "PANE"  { tty = $2; sub(/^\/dev\//, "", tty); pane[tty] = $3; next }
$1 == "PS"    { ttyof[$2] = $3; next }
$1 == "MTIME" { mtime[$2] = $3; next }

$1 == "SESS" {
  name = $2
  order[++sessions] = name
  role[name] = $3
  branch[name] = $4
  repo[name] = $5
  path[name] = $6
  next
}

$1 == "AGENT" {
  agents++
  akind[agents] = $2; apid[agents] = $3; asid[agents] = $4
  astatus[agents] = $5; aname[agents] = $6; acwd[agents] = $7
  next
}

END {
  for (i = 1; i <= agents; i++) {
    target = ""
    if (apid[i] != "" && apid[i] in ttyof && ttyof[apid[i]] in pane) target = pane[ttyof[apid[i]]]

    session = target
    sub(/:.*/, "", session)
    if (session != "") attached[session] = 1

    emit(target, asid[i], acwd[i], akind[i], astatus[i], aname[i], repo[session], branch[session])
  }

  for (i = 1; i <= sessions; i++) {
    name = order[i]
    if (name in attached) continue
    status = (role[name] == "") ? "shell" : role[name]
    emit(name ":", "", path[name], status, status, name, repo[name], branch[name])
  }
}
