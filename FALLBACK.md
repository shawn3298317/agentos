# Fallback: no Homebrew, no admin, or no time

The goal is the same workflow (one worktree per task, a Claude session in each, a place to
watch them all) using only what a locked-down Mac is likely to have. Try each tier in order.

## Tier 1: no admin, but the network works

Homebrew wants admin rights; these steps don't need them.

```bash
mkdir -p ~/.local/bin && export PATH="$HOME/.local/bin:$PATH"

# agent-deck: single static binary
V=1.16.16; A=$(uname -m | sed 's/x86_64/amd64/')
curl -fsSL "https://github.com/asheshgoplani/agent-deck/releases/download/v$V/agent-deck_${V}_darwin_${A}.tar.gz" | tar -xz -C ~/.local/bin agent-deck

# Claude Code: native installer, user-local
curl -fsSL https://claude.ai/install.sh | bash

# tmux and jq: if missing and brew isn't available, skip agent-deck and use Tier 2
command -v tmux jq

git clone https://github.com/<you>/agentos ~/agentos && ~/agentos/install.sh --no-packages
```

## Tier 2: only git and Claude Code

```bash
# one worktree per task
git worktree add .worktrees/deck-<slug> -b deck/<slug>
cd .worktrees/deck-<slug> && claude --permission-mode auto

# see what's in flight
git worktree list
git log --oneline main..deck/<slug>

# finish
git -C <repo> merge --no-ff deck/<slug> && git worktree remove .worktrees/deck-<slug>
```

Use Terminal.app tabs, or Ghostty if it's allowed, one per worktree. To keep a manual version
of the conductor's log, write `NOTES.md` in each worktree before you switch away from it.

## Tier 3: nothing installable

Talk through the plan and write code by hand. The workflow still applies: small branches,
review each diff before you merge, and write down your decisions.

## Before you leave

```bash
agentos uninstall --purge || {
  rm -rf ~/agentos ~/.agent-deck ~/.config/agent-deck ~/.local/share/agent-deck ~/.local/bin/agent-deck
  tmux kill-server 2>/dev/null; gh auth logout; security delete-generic-password -s "Claude Code-credentials"
}
```
