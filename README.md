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
session start rather than the last turn.

Session metadata (role, branch, repo) lives in tmux user options on the session
itself, so there is no state file to keep in sync.

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
| `prefix + g` | agent dashboard |
| `prefix + b` | work session on a branch |
| `prefix + e` | branch session with no agent |

The popup inherits the current pane's directory, which is how `b` and `e` find
the repo to act on. Rebind with `@phalanx-key`, `@phalanx-work-key` and
`@phalanx-bare-key`, or set one to `none` to skip it; `@phalanx-width` and
`@phalanx-height` size the popup, and `@phalanx-shell` (default `bash`) is the
shell it runs under as a login shell. Set options before `run-shell`, which is
when the plugin reads them.

These three avoid every default tmux binding and leave `h`/`j`/`k`/`l` free for
vim-style pane navigation.

Requires tmux >= 3.2, fzf, jq, git, Claude Code >= 2.1.139.

## Usage

| command | what it does |
| --- | --- |
| `phalanx` | dashboard: attach, create, kill |
| `phalanx new [path] [layout]` | session for a directory |
| `phalanx work <branch> [layout]` | worktree + session for a branch |
| `phalanx bare <branch>` | the same with a layout that runs no agent |
| `phalanx rm <branch>` | drop the session and its worktree, keeping the branch |
| `phalanx archive <branch>` | stash what is uncommitted, then drop it the same way |
| `phalanx archived` | what has been archived in this repo |
| `phalanx restore <branch>` | bring back a worktree, and its stash if there is one |
| `phalanx prune` | drop worktrees of branches already merged |
| `phalanx ls [-c]` | list sessions, `--tsv` for the machine-readable form |
| `phalanx --version` | print the version |

Nothing needs setting up per repo to get going: `cd` into one and run
`phalanx new .` for a session on the current checkout, or `phalanx work <branch>`
to get a worktree of its own. Nothing needs configuring first.

In the dashboard: `enter` attaches, `ctrl-b` opens a work session on a branch,
`ctrl-o` opens one with no agent, `ctrl-n` creates a session from a path, `ctrl-x`
kills a session, `ctrl-r` reloads. `esc` backs out of a picker to the list, and
out of the list to close. Anything that cannot be done on the chosen row says so
and waits for a key, rather than closing the popup.

`ctrl-x` kills the tmux session when the row has one. Where it does not, an agent
running outside tmux can still be stopped by its pid, on confirmation; a
background agent that reports neither has to be handled from `claude agents`,
which is what phalanx will tell you.

The current row is highlighted with a background, since rows carry their own
colours and a foreground change would not show through. `@phalanx-highlight`
sets it — 238 by default, which suits a dark theme.

The name and version sit on the popup's own border, which sizes itself, so the
list keeps the column names directly above it and the keys along the bottom.

A cyan bar in the left gutter marks what phalanx manages. It comes from the
`@phalanx-role` option on the session, which only phalanx sets, so anything that
grew on its own — a hand-rolled tmux session, an agent started outside phalanx —
has no bar and reads `external`, `background` or `detached` in the category
column.

`ls` prints what the dashboard shows. `--tsv` gives the raw rows instead, with
the pane target, session id and path the popup needs, which is what the reload
binding uses.

`-c` gives a narrower row for a laptop screen: the status word drops to its icon,
repo and branch share one column, the category shrinks to three letters and the
agent name is cut. Set `@phalanx-compact on` to get the same in the popup.

Age is time since the agent's last turn, from the transcript mtime. An agent that
has not taken a turn yet has no transcript, so it falls back to how long ago it
started.

Rows are ordered in two blocks. Agents come first, with state, how long since
the last turn, repo, branch, category and the agent's name. Plain tmux sessions
with no agent follow — bare sessions and ones whose agent is not running
— and since they have no state they show only repo and branch. The category
column is what names the block, because fzf has no unselectable rows and a
separator line would just be another thing to accidentally pick.

Repo and branch identify a work session on their own, since a branch gets one
worktree and one session. Background agents are the exception: they get no
session and no worktree of their own, so several of them share a repo and branch
and the name is all that tells them apart.

Rows that cannot be attached are dimmed and say so in the category: `background`
for an agent living inside a parent session, `detached` for one running outside
tmux. Branch falls back to whatever the directory is checked out on, so sessions
not created by phalanx still show one.

## One branch, one worktree, one session

Git refuses to check out a branch that another worktree already holds, so
switching branches inside a session breaks down as soon as you run several
sessions against one repo. phalanx inverts it: a branch gets a worktree under
`$PHALANX_HOME/worktrees/<repo>/<branch>` and a session named `<repo>/<branch>`.
Changing branch means changing session, and the conflict cannot arise.

`phalanx work` reuses an existing worktree if the branch already has one, so
running it twice for the same branch lands you in the same session.

### The default branch stays put

The main checkout holds the default branch and nothing else; every other branch
gets a worktree. That is the whole rule, and it is what makes the conflict
impossible rather than merely unlikely.

phalanx enforces it rather than hoping. `phalanx work` refuses if the branch you
asked for is checked out in the main worktree, and refuses to build a second
worktree for the default branch when the main one has drifted off it. In both
cases it prints the `git switch` that puts things right and changes nothing
itself.

### Getting rid of one

A worktree per branch means worktrees accumulate, so `rm` takes the session and
the worktree together and leaves the branch alone. What that costs you is nothing
you cannot get back: commits live in the branch ref whether or not they were ever
pushed, and git refuses outright to remove a worktree holding modified or
untracked files — which covers the `.env` this tool linked in itself. phalanx
never passes `--force` and never deletes a branch, so the refusal stands.

When that refusal is in your way, `archive` stashes the working tree, untracked
files included, and then removes it. The stash is tagged with the branch, which is
all the record there is: `archived` reads it back out of `git stash list` and
`restore` recreates the worktree and pops it. There is no second store to drift
out of step with the repository.

`prune` offers up the worktrees of branches already merged into the default one,
and only ever its own, under `$PHALANX_HOME` — a worktree you added by hand is not
phalanx's to remove. `ctrl-x` in the dashboard asks the same question: the session
alone, the worktree too, or archive it first.

### Sessions with no agent

phalanx is the agent and the tmux session together, so a session without one
looks like it misses the point. It does not, and the reason is the worktree rule
above: a branch can only be checked out in one place, and under that rule the only
place is a worktree phalanx made. So to touch a branch at all — to merge into it,
to look at it, to push it — it has to exist on disk somewhere, with or without an
agent in it.

An agent-less session is therefore not a second kind of session competing with
the first. It is what keeps the worktree rule livable, and without it the rule
would be a trap: every branch needs a worktree, but worktrees only come with
agents in them.

`phalanx bare <branch>` is `work` with a layout that runs no agent, which is why
it takes no separate concept and has no separate name of its own. Pushing to a
shared branch needs nothing more: go to the session that holds it and push.
Reaching a branch you have not checked out is possible — `git push origin
HEAD:refs/heads/staging` works from any worktree — but it leaves the worktree that
does hold the branch silently behind the remote, and forcing it after a fetch
overwrites whatever was pushed in the meantime. Merging where the branch actually
lives shows you the conflict instead.

The empty state column on such a row is not missing information. The category
says `plain`, which is the answer.

## Layouts

A layout is `window-name<TAB>command` per line. An empty command leaves a shell.

```
editor	nvim
agent	claude
shell
```

The layout decides whether the session runs an agent, and phalanx reads the
answer off it rather than off which command you typed: a layout with a window
named `agent` gives role `agent`, one without gives `plain`. The name is what is
checked, not the command, so `claude --resume` or a wrapper is fine.

Leave the layout unnamed and phalanx insists on an agent, because that is the
path you take without thinking and a default quietly missing its agent window
would kill the dashboard. Name a layout and it is taken as deliberate, so
`phalanx new . bare` is fine while `phalanx new .` against an agent-less default
is refused.

Lookup order: `<path>/.phalanx`, `~/.config/phalanx/layouts/<name>`, then
`layouts/<name>` here. `work` follows the same order, so a repo can ship the
layout its own sessions use. Commands are sent with `send-keys` rather than run as the
window command, so quitting nvim or claude leaves a shell instead of closing the
window.

## Repo config

Per repo, in `<repo>/.phalanx.conf` or `~/.config/phalanx/repos/<repo>`. See
`examples/repo.conf`.

```
link	.env
copy	.tool-versions
postcreate	npm ci
```

`link` symlinks a path from the main worktree into each new one, `copy` copies it,
and `postcreate` runs a command in the new worktree. Untracked files do not follow
a `git worktree add`, and that — not the branch bookkeeping — is what usually
makes worktrees unpleasant. Nothing here is required to get started.

## Agent state

Background agents report `state` while interactive ones report `status`, two
field names for the same idea. Background agents have no pid and live inside a
parent session, so they cannot be attached to directly. tmux sessions with no
agent still appear, which is how bare sessions stay visible.
