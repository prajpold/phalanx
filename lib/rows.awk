function paint(text, code) {
  return "\033[" code "m" text "\033[0m"
}

function icon(status) {
  if (status == "busy" || status == "running") return "●"
  if (status == "idle") return "○"
  if (status == "blocked" || status == "waiting") return "◆"
  if (status == "error") return "✗"
  if (status == "ops") return "⚙"
  return "▪"
}

function status_color(status) {
  if (status == "busy" || status == "running") return "32"
  if (status == "blocked" || status == "waiting") return "33"
  if (status == "error") return "31"
  if (status == "ops") return "36"
  return "2"
}

function category(kind, role, target) {
  if (kind == "background") return "background"
  if (target == "") return "detached"
  if (role == "ops") return "ops"
  if (role == "") return "external"
  return "phalanx"
}

function short_category(cat) {
  if (cat == "background") return "bg"
  if (cat == "detached") return "det"
  if (cat == "external") return "ext"
  if (cat == "phalanx") return "phx"
  return cat
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

function trunc(s, w) {
  return (length(s) <= w) ? s : substr(s, 1, w)
}

function fit(s, w) {
  if (length(s) <= w) return sprintf("%-" w "s", s)
  return substr(s, 1, w - 1) "…"
}

function basename(p,   n, a) {
  n = split(p, a, "/")
  return n ? a[n] : p
}

function emit(target, sid, cwd, kind, status, repo, br, role, agent, started, pid,
              cat, group, gutter, state, age, ident, disp) {
  if (repo == "") repo = basename(cwd)
  if (br == "" && cwd in gitbranch) br = gitbranch[cwd]
  if (br == "") br = "-"

  cat = category(kind, role, target)
  group = (sid == "") ? 2 : 1
  gutter = (role == "") ? "  " : paint("▌", "36") " "

  if (group == 1) {
    state = paint(sprintf("%s %-8s", icon(status), status), status_color(status))
  } else {
    state = paint(sprintf("%s %-8s", icon(status), ""), status_color(status))
  }

  age = ago(mtime[sid])
  # No transcript yet means no turn yet, so fall back to when the agent started.
  if (age == "-" && started != "") age = ago(int(started / 1000))

  if (compact) {
    ident = (br == "-") ? trunc(repo, 30) : trunc(repo, 16) "/" trunc(br, 13)
    disp = sprintf("%s%s %4s  %s %s %s",
                   gutter,
                   paint(icon(status), status_color(status)),
                   age,
                   paint(sprintf("%-4s", short_category(cat)), "2"),
                   paint(sprintf("%-30s", ident), "1"),
                   paint(trunc(agent, 35), "2"))
    print target, sid, cwd, kind, disp, repo, group, pid
    return
  }

  {
    disp = sprintf("%s%s %4s  %s %s %s %s",
                   gutter, state, age,
                   paint(fit(repo, 20), "1"),
                   paint(fit(br, 22), "36"),
                   paint(sprintf("%-11s", cat), "2"),
                   paint(agent, "2"))
  }

  print target, sid, cwd, kind, disp, repo, group, pid
}

$1 == "PANE"   { tty = $2; sub(/^\/dev\//, "", tty); pane[tty] = $3; next }
$1 == "PS"     { ttyof[$2] = $3; next }
$1 == "MTIME"  { mtime[$2] = $3; next }
$1 == "BRANCH" { gitbranch[$2] = $3; next }

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
  astarted[agents] = $8
  next
}

END {
  for (i = 1; i <= agents; i++) {
    target = ""
    if (apid[i] != "" && apid[i] in ttyof && ttyof[apid[i]] in pane) target = pane[ttyof[apid[i]]]

    session = target
    sub(/:.*/, "", session)
    if (session != "") attached[session] = 1

    emit(target, asid[i], acwd[i], akind[i], astatus[i],
         repo[session], branch[session], role[session], aname[i], astarted[i], apid[i])
  }

  for (i = 1; i <= sessions; i++) {
    name = order[i]
    if (name in attached) continue
    status = (role[name] == "") ? "shell" : role[name]
    emit(name ":", "", path[name], status, status,
         repo[name], branch[name], role[name], "", "", "")
  }
}
