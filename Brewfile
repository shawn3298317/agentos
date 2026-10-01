# macOS packages for agentos. install.sh runs `brew bundle` with this file.
tap "asheshgoplani/tap"

brew "git"
brew "tmux"                 # agent-deck runs every session in tmux
brew "jq"                   # hooks, settings merge, agentos doctor
brew "gh"                   # PRs from worktree sessions
brew "node"
brew "ripgrep"
brew "fd"
# Intel Macs on current macOS are Homebrew Tier 3: no bottles, so these compile from
# source (terminal-notifier needs full Xcode, agent-deck drags in a long dependency
# build). There, install.sh installs the prebuilt agent-deck release instead.
if `uname -m`.strip == "arm64"
  brew "terminal-notifier"  # local escalation notifications (no Telegram on a loaner)
  brew "asheshgoplani/tap/agent-deck"
end

cask "ghostty"
cask "font-jetbrains-mono"
cask "claude-code"
