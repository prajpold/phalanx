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
  if (role == "") return "external"
  if (role == "plain") return "plain"
  return "agent"
}

function short_category(cat) {
  if (cat == "background") return "bg"
  if (cat == "detached") return "det"
  if (cat == "external") return "ext"
  if (cat == "plain") return "pln"
  if (cat == "agent") return "agt"
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

# Collected rather than printed, because whether the divergence column exists at
# all depends on every row having been seen.
function collect(target, sid, cwd, kind, status, repo, br, role, agent, started, pid,
                 actual) {
  rows++
  actual = (cwd in gitbranch) ? gitbranch[cwd] : ""

  R_target[rows] = target
  R_sid[rows] = sid
  R_cwd[rows] = cwd
  R_kind[rows] = kind
  R_status[rows] = status
  R_pid[rows] = pid
  R_repo[rows] = (repo == "") ? basename(cwd) : repo
  R_cat[rows] = category(kind, role, target)
  R_agent[rows] = agent
  R_group[rows] = (sid == "") ? 2 : 1
  R_gutter[rows] = (role == "") ? "  " : paint("▌", "36") " "

  R_branch[rows] = (br != "") ? br : ((actual != "") ? actual : "-")

  # Only a session pinned to a branch can drift off it; anything else is just
  # reporting where it happens to be.
  if (br != "" && actual != "" && actual != br) {
    R_actual[rows] = actual
    diverged = 1
  } else {
    R_actual[rows] = ""
  }

  R_age[rows] = ago(mtime[sid])
  if (R_age[rows] == "-" && started != "") R_age[rows] = ago(int(started / 1000))
}

function render(i,   state, ident, disp) {
  if (compact) {
    ident = (R_actual[i] != "") ? "≠" trunc(R_actual[i], 12) : trunc(R_branch[i], 13)
    ident = trunc(R_repo[i], 16) "/" ident
    disp = sprintf("%s%s %4s  %s %s %s",
                   R_gutter[i],
                   paint(icon(R_status[i]), status_color(R_status[i])),
                   R_age[i],
                   paint(sprintf("%-4s", short_category(R_cat[i])), "2"),
                   paint(sprintf("%-30s", ident), "1"),
                   paint(trunc(R_agent[i], 35), "2"))
  } else {
    if (R_group[i] == 1) {
      state = sprintf("%s %-8s", icon(R_status[i]), R_status[i])
    } else {
      state = sprintf("%s %-8s", icon(R_status[i]), "")
    }
    state = paint(state, status_color(R_status[i]))

    disp = sprintf("%s%s %4s  %s %s%s %s %s",
                   R_gutter[i], state, R_age[i],
                   paint(fit(R_repo[i], 20), "1"),
                   paint(fit(R_branch[i], 22), "36"),
                   diverged ? " " paint(fit(R_actual[i], 18), "33") : "",
                   paint(sprintf("%-11s", R_cat[i]), "2"),
                   paint(R_agent[i], "2"))
  }

  print R_target[i], R_sid[i], R_cwd[i], R_kind[i], disp, R_repo[i], R_group[i], R_pid[i], R_actual[i]
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

    collect(target, asid[i], acwd[i], akind[i], astatus[i],
            repo[session], branch[session], role[session], aname[i], astarted[i], apid[i])
  }

  for (i = 1; i <= sessions; i++) {
    name = order[i]
    if (name in attached) continue
    status = (role[name] == "") ? "shell" : role[name]
    collect(name ":", "", path[name], status, status,
            repo[name], branch[name], role[name], "", "", "")
  }

  for (i = 1; i <= rows; i++) render(i)
}
