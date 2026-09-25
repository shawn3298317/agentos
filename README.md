# agentos

My local agent orchestration setup: **agent-deck** (conductors + one git worktree per
Claude Code session), **Claude Code**, and **Ghostty**. It takes one command to go from a
fresh Mac to a working setup, and one command to remove it all again.

```bash
# fresh Mac (brings Homebrew → git → everything else)
curl -fsSL https://raw.githubusercontent.com/<you>/agentos/main/bootstrap.sh | AGENTOS_GIT_URL=https://github.com/<you>/agentos.git bash

# or, with git already available
git clone https://github.com/<you>/agentos ~/agentos && ~/agentos/install.sh
```

Then do these one-time steps (they need a browser):

```bash
exec $SHELL -l                                   # PATH
claude                                           # /login, then /exit
gh auth login                                    # optional, for PR flows
agent-deck                                       # accept "install Claude hooks"
agent-deck session start conductor-fleet-spawner
agentos doctor
```

When you're done with a borrowed machine:

```bash
agentos uninstall --purge   # removes links/configs, restores backups, kills agentdeck tmux
                            # sessions, wipes agent-deck state, logs out of gh + Claude
```

## What gets installed

| Piece | Where | How |
|---|---|---|
| Homebrew packages: git, tmux, jq, gh, node, rg, fd, terminal-notifier, agent-deck; casks ghostty, JetBrains Mono, claude-code | system | `Brewfile` |
| Ghostty config | `~/.config/ghostty/config` | symlink → `ghostty/config` |
| agent-deck config | `~/.config/agent-deck/config.toml` | rendered copy of `agent-deck/config.toml` (the TUI rewrites it atomically, so it can't be a symlink) |
| Conductors `fleet-spawner`, `reviewer` | `~/.agent-deck/conductor/<name>/` | `agent-deck conductor setup` with `CLAUDE.md` symlinked to the repo; installs the launchd heartbeat |
| Conductor state hooks | `<conductor>/.claude/settings.json` | merged next to agent-deck's own permission policy |
| Claude Code | `~/.claude/` | `settings.base.json` **merged** into `settings.json`; `CLAUDE.md`, `skills/*`, `commands/*`, `agents/*`, `hooks/*` symlinked |
| `agentos`, `agentos-conductor-hook` | `~/.local/bin/` | symlinks |

Anything that already exists gets backed up to `~/.local/state/agentos/backups/` before it's
replaced. Everything agentos creates is recorded in `~/.local/state/agentos/manifest`, and
uninstall uses that manifest to undo it.

## Decisions baked into the config

- **agent-deck ≥ 1.16** (`versions.env`), because 0.27 never ran conductor heartbeats. 1.16 installs a
  launchd job per conductor, has truthful `session send` exit codes, `session children --follow`,
  recall (cross-session transcript search, TUI `G`), worktree script consent, and pricing that's current.
- **`dangerous_mode = false`, `auto_mode = true`.** Note that agent-deck defaults dangerous_mode to
  *true* when it's unset. Bypass is still one flag away (`--skip-permissions`). Conductors spawn
  children with `--auto-mode` unless a task asks for bypass.
- **`branch_prefix = ""`.** The default `feature/` turns `-w deck/x` into `feature/deck/x`.
- **`auto_cleanup = false`.** Removing a session never deletes its worktree.
- **`[conductor] dir = ~/.agent-deck/conductor`** pins the conductor root, so paths in the
  instructions and hooks are the same on every machine.

## Conductor memory (P1)

Conductors were told to keep `state.json`, `task-log.md` and `LEARNINGS.md` up to date, and they never
did. That's now enforced by `bin/agentos-conductor-hook`:

- **SessionStart** (startup/resume/compact/clear): bootstraps the files and injects state, the last
  60 log lines, and active learnings into context. This matters because 1.16 `/clear`s conductors
  when their context fills.
- **Stop:** refreshes `state.json.fleet` from `agent-deck status --json`, and **blocks the end of the turn
  once** if `task-log.md` wasn't appended. Set `AGENTOS_ENFORCE_TASKLOG=0` in the conductor env to disable it.
- **UserPromptSubmit / SessionEnd:** turn markers, `last_heartbeat`, and `events.jsonl`.

## Scripts

- `scripts/import-local.sh`: run on the main machine to pull `~/.claude/{CLAUDE.md,skills,commands,agents,hooks}`
  and the Ghostty config into the repo. It runs a secret scan before anything gets committed.
- `scripts/migrate-local.sh`: one-time migration for the original machine. It snapshots `~/.agent-deck`,
  upgrades to 1.16, re-runs install, restarts conductors in error, and re-adopts sessions that live in
  `.worktrees/` without worktree metadata. Each session keeps its worktree and resumes its Claude conversation.
- `test/run.sh`: builds a bare Ubuntu image and runs `test/e2e.sh`, which checks a fresh install,
  idempotency, doctor, the hooks, worktree naming, migration, and uninstall/purge.

## If the install can't run

See [FALLBACK.md](FALLBACK.md). It covers the same workflow by hand with `claude` + `git worktree`,
for when Homebrew is blocked or you don't have admin rights.
