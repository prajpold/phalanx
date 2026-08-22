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

```sh
curl -fsSL https://raw.githubusercontent.com/prajpold/phalanx/master/install.sh | bash
```

That takes the newest tag, keeps its own clone under `~/.local/share/phalanx`,
links `bin/phalanx` into `~/.local/bin`, puts that directory on your `PATH` and
binds the popup keys in your tmux config — reloading a running server, so they
work without reattaching. Pass a version to pin one, or a branch to track its
tip:

```sh
curl -fsSL https://raw.githubusercontent.com/prajpold/phalanx/master/install.sh | bash -s -- v0.3.0
```

It writes to `~/.zshrc`, `~/.bash_profile` or `~/.config/fish/config.fish`
depending on `$SHELL`, and to `~/.tmux.conf`. Both edits go in a block between
`# phalanx begin` and `# phalanx end` that it rewrites in place, so installing
twice leaves one entry and moving `PHALANX_PREFIX` does not strand the old path.
A `run-shell` you wrote yourself is left alone rather than doubled up, and
`--no-path` and `--no-tmux` skip either edit and print what to add yourself.

`~/.tmux.conf` deliberately, even when you keep your config in
`~/.config/tmux/tmux.conf`: tmux reads both, in that order, so the popup keys can
live in a file phalanx owns and your own config never gets edited. That matters
when a dotfiles repo owns it through a symlink — writing over that link swaps it
for a plain file, and the next `stow` or install run moves that file aside and
relinks, taking the block with it weeks later. Where a block does have to be
touched it is written through the link rather than over it, and a block an older
install left in the XDG config is dropped rather than left to bind the keys a
second time. One consequence: `~/.tmux.conf` is read *first*, so `@phalanx-*`
options belong there too — set in the XDG config they arrive after the keys are
already bound. Lines you add outside the markers are kept.

Rerun `~/.local/share/phalanx/install.sh` to update — it is the same script, and
the clone it made is the one it installs from. `PHALANX_PREFIX` and
`PHALANX_BIN_DIR` move where it puts things, and `PHALANX_REPO` where it pulls
from.

Needs `tmux`, `jq`, `fzf` and `git` on your `PATH`; the installer names the ones
you are missing.

| bind | opens |
| --- | --- |
| `prefix + g` | the dashboard |
| `prefix + b` | a new session with a worktree of its own |
| `prefix + e` | the session for this checkout, no questions asked |

The popup inherits the current pane's directory, which is how it finds the repo
to act on. Rebind with `@phalanx-key`, `@phalanx-worktree-key` and
`@phalanx-main-key`, or set one to `none` to skip it; `@phalanx-width` and
`@phalanx-height` size the popup, and `@phalanx-shell` (default `bash`) is the
shell it runs under as a login shell, defaulting to tmux's own `default-shell`.
Set options before `run-shell`, which is when the plugin reads them — in the same
file, since that is `~/.tmux.conf` and it is read before your XDG config.

Requires tmux >= 3.2, fzf, jq, git, Claude Code >= 2.1.139.

## Usage

| command | what it does |
| --- | --- |
| `phalanx` | the dashboard: attach, create, remove |
| `phalanx new [name]` | session in this repo's checkout, called `main` if you leave the name out |
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

In the dashboard there are two ways to make a session. `ctrl-n` picks a repo and
that is the whole flow: it opens the repo's own checkout as a session called
`main`, and picking a repo that already has one attaches to it instead. `ctrl-b`
adds a worktree session to the repo of the highlighted row, and names that repo
in both its prompts so it is clear which one you are branching off.

The rest: `enter` attaches, `ctrl-x` removes, `ctrl-r` reloads. `esc` backs out
of a picker to the list, and out of the list to close.
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
through one of them. The one exception is the session in the repo's own
checkout — there is only ever one of those per repo, so it is called `main`
without asking, and `PHALANX_MAIN_SESSION` renames it.

Where it runs is the one real choice. `--worktree` gives the session a checkout of
its own under `$PHALANX_HOME/worktrees/<repo>/<name>`, named after the session, so
the session name is the only handle you need for anything afterwards. A worktree
is still not a branch — it outlives any branch checked out in it, which is why
`--branch` is a separate flag and only says where to start.

Without `--worktree` the session runs in the repo's main checkout. That is where
a repo starts: one session in the checkout, then worktree sessions hung off it as
the work splits.

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

`tests/install` runs the installer itself against a throwaway `HOME`, because
the thing it must not do — write over a config another tool owns — only shows up
on the filesystem.

`tests/e2e` drives the whole lifecycle — create, archive, restore, remove, prune
— against a tmux server, a `PHALANX_HOME` and a git repo of its own, so a run
cannot see or kill anything you are working in.

```sh
tests/smoke && tests/e2e
```

## License

MIT, see [LICENSE](LICENSE).
