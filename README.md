# phalanx

A tmux session manager for coding agents. One session per task, one window per
role, and a dashboard that reads each agent's own reported state.

## How it works

`claude agents --json` reports every running agent with its state, pid and cwd,
so there is no daemon, no hooks and no PTY scraping. phalanx joins that output
to tmux panes over the controlling tty — `pane_pid` is the shell and the agent
is its child, so the tty is the only reliable key.

Last-activity age comes from the transcript mtime under
`~/.claude/projects/<slug>/<sessionId>.jsonl`, because `startedAt` is the
session start rather than the last turn. An agent that has not taken a turn yet
has no transcript, so it falls back to when it started.

Session metadata lives in tmux user options on the session itself, so there is
no state file to keep in sync. The branch is not among them: it is read from git
on every refresh, because a session does not own a branch and switching inside a
worktree has to show up.

## Install

Clone anywhere, put the command on your `PATH`, then add to
`~/.config/tmux/tmux.conf`:

```sh
ln -s "$PWD/bin/phalanx" ~/.local/bin/phalanx
```

```tmux
run-shell /path/to/phalanx/phalanx.tmux
```

| bind | opens |
| --- | --- |
| `prefix + g` | the dashboard |
| `prefix + b` | a new session with a worktree of its own |
| `prefix + e` | a new session in this checkout |

The popup inherits the current pane's directory, which is how it finds the repo
to act on. Rebind with `@phalanx-key`, `@phalanx-worktree-key` and
`@phalanx-main-key`, or set one to `none` to skip it; `@phalanx-width` and
`@phalanx-height` size the popup, and `@phalanx-shell` (default `bash`) is the
shell it runs under as a login shell. Set options before `run-shell`, which is
when the plugin reads them.

Requires tmux >= 3.2, fzf, jq, git, Claude Code >= 2.1.139.

## Usage

| command | what it does |
| --- | --- |
| `phalanx` | the dashboard: attach, create, remove |
| `phalanx new <name>` | session in this repo's checkout |
| `phalanx new <name> --worktree` | session with a worktree of its own |
| `phalanx rm <name>` | drop a session and its worktree |
| `phalanx archive <name>` | stash what is uncommitted, then drop it |
| `phalanx archived` | what has been archived in this repo |
| `phalanx restore <name>` | bring a session back, and its stash if any |
| `phalanx prune` | drop worktrees whose session is gone |
| `phalanx ls [-c]` | list sessions, `--tsv` for the machine-readable form |
| `phalanx --version` | print the version |

`--layout <name>` picks the windows and `--branch <branch>` says which branch a
new worktree starts on. Nothing needs configuring first.

In the dashboard: `enter` attaches, `ctrl-b` and `ctrl-e` create a session with
or without a worktree, `ctrl-n` switches repo, `ctrl-x` removes, `ctrl-r`
reloads. `esc` backs out of a picker to the list, and out of the list to close.
Anything that cannot be done on the chosen row says so and waits for a key,
rather than closing the popup.

`ls` prints what the dashboard shows. `--tsv` gives the raw rows, with the pane
target, session id and path the popup needs, which is what the reload binding
uses. `-c` narrows the row for a laptop screen: the status word drops to its
icon, repo and branch share a column, the category shrinks to three letters and
the agent name is cut. `@phalanx-compact on` does the same in the popup.

## Sessions

A session is a name, a directory and a layout. The name is yours to pick, which
matters because a session is not a branch: you might carry a stack of three
through one of them.

Where it runs is the one real choice. `--worktree` gives the session a checkout of
its own under `$PHALANX_HOME/worktrees/<repo>/<name>`, named after the session, so
the session name is the only handle you need for anything afterwards. A worktree
is still not a branch — it outlives any branch checked out in it, which is why
`--branch` is a separate flag and only says where to start.

Without `--worktree` the session runs in the repo's main checkout.

That second option comes with a hazard worth stating: two sessions in one
checkout are two agents writing to the same working tree, and a branch switch in
either silently moves the other. phalanx says so and asks before making the
second one, and the branch column is read live so the drift is at least visible.

The category column names which is which: `main`, `worktree`, `external` for a
tmux session phalanx did not create, `background` and `detached` for agents with
no pane of their own. A cyan bar in the left gutter marks what phalanx manages.
Rows saying `background` or `detached` cannot be attached to.

Sessions are acted on by tmux's own session id rather than by name, since two
repos with the same directory name would otherwise collide. Removing the session
you are attached to moves the client to the most recently used other one first,
and is refused outright when there is no other one to move to.

## Removing one

A worktree per session means worktrees accumulate, so `rm` takes the session and
the worktree together and leaves the branch alone. What that costs you is nothing
you cannot get back: commits live in the branch ref whether or not they were ever
pushed, and git refuses outright to remove a worktree holding modified or
untracked files — which covers the `.env` this tool linked in itself. phalanx
never passes `--force` and never deletes a branch, so the refusal stands.

When that refusal is in your way, `archive` stashes the working tree, untracked
files included, tagged with the session name and the branch it was on. The branch
also goes into the repository's own config, so a worktree with nothing to stash is
still listed and still comes back on the branch it was on rather than a fresh one.
`restore` recreates the worktree, pops the stash if there is one, and opens the
session under the name it had.

Prompts and confirmations are fzf, not bare terminal writes, so they carry the
same frame and keys as the list. Where no terminal is attached they fall back to a
plain read, which keeps the command line scriptable.

`prune` offers up the worktrees whose session is gone, and only its own, under
`$PHALANX_HOME` — a worktree you added by hand is not phalanx's to remove.
`ctrl-x` asks the same question: the session alone, the worktree too, or archive
it first.

## Layouts

A layout is `window-name<TAB>command` per line. An empty command leaves a shell.

```
editor	nvim
agent	claude
shell
```

Lookup order: `<path>/.phalanx`, `~/.config/phalanx/layouts/<name>`, then
`layouts/<name>` here. Commands are sent with `send-keys` rather than run as the
window command, so quitting nvim or claude leaves a shell instead of closing the
window.

Leave `--layout` off and phalanx insists the layout has a window named `agent`,
because that is the path you take without thinking and a default quietly missing
its agent window would leave the dashboard with nothing to report. Name a layout
and it is taken as deliberate, so `--layout bare` gets you a session with no
agent for whatever you would rather do by hand. The check is on the window name,
not the command, so `claude --resume` or a wrapper is fine.

`PHALANX_ROOTS` (colon-separated, default `~/repos`) sets where `ctrl-n` looks
for repos.

## Repo config

Per repo, in `<repo>/.phalanx.conf` or `~/.config/phalanx/repos/<repo>`. See
`examples/repo.conf`.

```
link	.env
copy	.tool-versions
postcreate	npm ci
```

`link` symlinks a path from the main checkout into each new worktree, `copy`
copies it, and `postcreate` runs a command there. Untracked files do not follow a
`git worktree add`, and that — not the branch bookkeeping — is what usually makes
worktrees unpleasant. Nothing here is required to get started.

## Agent state

Background agents report `state` while interactive ones report `status`, two
field names for the same idea. Not every background agent lacks a pid, so what
`ctrl-x` can do is decided by the pid, not the kind: a row with a session gets
the session killed, one with only a pid offers to signal the process, and one
with neither is handed back to `claude agents`, which has no CLI to stop it.

tmux sessions with no agent still appear, which is how a session whose agent is
not running stays visible.

## Tests

`tests/smoke` checks the seams a shell script has no compiler for: that the
dispatcher only calls functions that exist, that awk and fzf accept what the code
builds, and that nothing in `lib` ever passes `--force` to a worktree removal or
deletes a branch.

## License

MIT, see [LICENSE](LICENSE).
