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
| `prefix + e` | ops session on an environment branch |

The popup inherits the current pane's directory, which is how `b` and `e` find
the repo to act on. Rebind with `@phalanx-key`, `@phalanx-work-key` and
`@phalanx-ops-key`, or set one to `none` to skip it; `@phalanx-width` and
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
| `phalanx work <branch>` | worktree + session for a branch |
| `phalanx ops <branch>` | terminal-only session for merges and rebases |
| `phalanx ls` | dashboard rows as TSV, for scripting |
| `phalanx --version` | print the version |

Nothing needs setting up per repo to get going: `cd` into one and run
`phalanx new .` for a session on the current checkout, or `phalanx work <branch>`
to get a worktree of its own. Only `ops` needs a repo config, since it has no way
to guess which branches an environment deploys from.

In the dashboard: `enter` attaches, `ctrl-b` opens a work session on a branch,
`ctrl-o` opens an ops session, `ctrl-n` creates a session from a path, `ctrl-x`
kills a session, `ctrl-r` reloads.

The name and version sit on the popup's own border, which sizes itself, so the
list keeps the column names directly above it and the keys along the bottom.

A cyan bar in the left gutter marks what phalanx manages. It comes from the
`@phalanx-role` option on the session, which only phalanx sets, so anything that
grew on its own — a hand-rolled tmux session, an agent started outside phalanx —
has no bar and reads `external`, `background` or `detached` in the category
column.

Age is time since the agent's last turn, from the transcript mtime. An agent that
has not taken a turn yet has no transcript, so it falls back to how long ago it
started.

Rows are ordered in two blocks. Agents come first, with state, how long since
the last turn, repo, branch, category and the agent's name. Plain tmux sessions
with no agent follow — ops sessions and work sessions whose agent is not running
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

### Ops sessions

An ops session is a terminal-only session — no editor, no agent — for merges,
rebases and realigning an environment branch with the mainline. It is an ordinary
work session with a different layout, so it holds the branch in a worktree of its
own like any other, and that is what keeps a shared branch to a single writer.

Pushing to a shared branch needs nothing special as a result: go to its ops
session and push. Reaching a branch you have not checked out is possible
(`git push origin HEAD:refs/heads/staging` works from any worktree, even one that
does not hold it) but pointless here, and worse — it leaves the worktree that
does hold the branch silently behind the remote, and forcing it after a fetch
overwrites whatever was pushed in the meantime. An explicit merge in the ops
session shows you the conflict instead.

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
agent still appear, which is how ops sessions stay visible.
