function paint(text, code) {
  return "\033[" code "m" text "\033[0m"
}

function icon(status) {
  if (status == "busy" || status == "running") return "●"
  if (status == "idle") return "○"
  if (status == "blocked" || status == "waiting") return "◆"
  if (status == "error") return "✗"
  return "▪"
}

function status_color(status) {
  if (status == "busy" || status == "running") return "32"
  if (status == "blocked" || status == "waiting") return "33"
  if (status == "error") return "31"
  return "2"
}

function category(kind, location, target) {
  if (kind == "background") return "background"
  if (target == "") return "detached"
  if (location == "") return "external"
  return location
}

function short_category(cat) {
  if (cat == "background") return "bg"
  if (cat == "detached") return "det"
  if (cat == "external") return "ext"
  if (cat == "worktree") return "wt"
  return cat
}

function trunc(s, w) {
  return (length(s) <= w) ? s : substr(s, 1, w)
}

function fit(s, w) {
  if (length(s) <= w) return sprintf("%-" w "s", s)
  return substr(s, 1, w - 1) "…"
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

function emit(target, sid, cwd, kind, status, repo, location, agent, started, pid, session, sessionid,
              cat, group, gutter, state, age, branch, sname, ident, disp) {
  if (repo == "") repo = basename(cwd)

  sname = session
  if (sname == "") sname = "-"
  else if (index(sname, repo "/") == 1) sname = substr(sname, length(repo) + 2)
  branch = (cwd in gitbranch) ? gitbranch[cwd] : ""
  if (branch == "") branch = "-"

  cat = category(kind, location, target)
  group = (sid == "") ? 2 : 1
  gutter = (location == "") ? "  " : paint("▌", "36") " "

  age = ago(mtime[sid])
  # No transcript yet means no turn yet, so fall back to when the agent started.
  if (age == "-" && started != "") age = ago(int(started / 1000))

  if (compact) {
    ident = (sname == "-") ? trunc(repo, 28) : trunc(repo, 14) "/" trunc(sname, 13)
    disp = sprintf("%s%s %4s  %s %s %s %s",
                   gutter,
                   paint(icon(status), status_color(status)),
                   age,
                   paint(sprintf("%-4s", short_category(cat)), "2"),
                   paint(sprintf("%-28s", ident), "1"),
                   paint(sprintf("%-10s", trunc(branch, 10)), "36"),
                   paint(trunc(agent, 26), "2"))
  } else {
    if (group == 1)
      state = paint(sprintf("%s %-8s", icon(status), status), status_color(status))
    else
      state = paint(sprintf("%s %-8s", icon(status), ""), status_color(status))

    disp = sprintf("%s%s %4s  %s %s %s %s %s",
                   gutter, state, age,
                   paint(fit(repo, 20), "1"),
                   paint(fit(sname, 20), "35"),
                   paint(fit(branch, 14), "36"),
                   paint(sprintf("%-11s", cat), "2"),
                   paint(trunc(agent, 28), "2"))
  }

  print target, sid, cwd, kind, disp, repo, group, pid, sessionid
}

$1 == "PANE"   { tty = $2; sub(/^\/dev\//, "", tty); pane[tty] = $3; paneid[tty] = $4; next }
$1 == "PS"     { ttyof[$2] = $3; next }
$1 == "MTIME"  { mtime[$2] = $3; next }
$1 == "BRANCH" { gitbranch[$2] = $3; next }

$1 == "SESS" {
  name = $2
  order[++sessions] = name
  loc[name] = $3
  repo[name] = $4
  path[name] = $5
  sessid[name] = $6
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

    sessionid = ""
    if (apid[i] != "" && apid[i] in ttyof && ttyof[apid[i]] in paneid) sessionid = paneid[ttyof[apid[i]]]

    emit(target, asid[i], acwd[i], akind[i], astatus[i],
         repo[session], loc[session], aname[i], astarted[i], apid[i], session, sessionid)
  }

  for (i = 1; i <= sessions; i++) {
    name = order[i]
    if (name in attached) continue
    emit(name ":", "", path[name], "session", "shell",
         repo[name], loc[name], "", "", "", name, sessid[name])
  }
}
