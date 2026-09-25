#!/usr/bin/env bash
# agentos installer: one command from a fresh Mac to a working agent-deck + Claude Code
# + Ghostty setup. Idempotent; safe to re-run.
#
#   ./install.sh                 install / update everything
#   ./install.sh --dry-run       print what would change, change nothing
#   ./install.sh --no-packages   skip brew/apt/npm (dotfiles + conductors only)
#   ./install.sh --no-conductors skip `agent-deck conductor setup`
#   ./install.sh --uninstall [--purge]
#                                remove what agentos installed and restore backups;
#                                --purge also wipes agent-deck state, tmux sessions and
#                                logs out of claude/gh (use this before returning a loaner)
set -euo pipefail

AGENTOS_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AGENTOS_REPO
# shellcheck source=lib/common.sh
. "$AGENTOS_REPO/lib/common.sh"
# shellcheck source=versions.env
. "$AGENTOS_REPO/versions.env"

DRY_RUN=0; PACKAGES=1; CONDUCTORS=1; UNINSTALL=0; PURGE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --no-packages) PACKAGES=0 ;;
    --no-conductors) CONDUCTORS=0 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown flag: $a (see --help)" ;;
  esac
done
export DRY_RUN

BIN_DIR="$HOME/.local/bin"
CONDUCTOR_ROOT="$HOME/.agent-deck/conductor"
export PATH="$BIN_DIR:/opt/homebrew/bin:/usr/local/bin:$PATH"

sudo_if_needed() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

# ────────────────────────────────────────────────────────────────────────────
# Uninstall
# ────────────────────────────────────────────────────────────────────────────
do_uninstall() {
  step "Uninstalling agentos"
  if have agent-deck && [ "$PURGE" = 1 ]; then
    run agent-deck conductor teardown --all --remove --json >/dev/null 2>&1 || warn "conductor teardown reported errors"
  fi
  if [ -f "$AGENTOS_MANIFEST" ]; then
    # Reverse order: undo links/files first, then restore backups over them.
    local kind a b
    while IFS=$'\t' read -r kind a b; do
      case "$kind" in
        link) if [ -L "$a" ] && [ "$(readlink "$a")" = "$b" ]; then run rm -f "$a"; ok "unlinked ${a/#$HOME/~}"; fi ;;
        file) if [ -f "$a" ]; then run rm -f "$a"; ok "removed  ${a/#$HOME/~}"; fi ;;
      esac
    done < <(tail -r "$AGENTOS_MANIFEST" 2>/dev/null || tac "$AGENTOS_MANIFEST")
    while IFS=$'\t' read -r kind a b; do
      if [ "$kind" = backup ] && { [ -e "$b" ] || [ -L "$b" ]; } && [ ! -e "$a" ]; then
        run mkdir -p "$(dirname "$a")"; run mv "$b" "$a"; ok "restored ${a/#$HOME/~}"
      fi
    done < <(tail -r "$AGENTOS_MANIFEST" 2>/dev/null || tac "$AGENTOS_MANIFEST")
  else
    warn "no manifest at $AGENTOS_MANIFEST; nothing recorded to undo"
  fi
  # settings.json was merged (not linked): strip only the agentos-owned hook entries.
  local s="$HOME/.claude/settings.json"
  if [ -f "$s" ] && have jq && [ "$DRY_RUN" = 0 ]; then
    jq 'if .hooks then .hooks |= with_entries(.value |= map(select((.hooks // []) | all(.command | test("agentos") | not)))) else . end' \
      "$s" >"$s.tmp" && mv "$s.tmp" "$s"
  fi
  sed_rc_block remove
  if [ "$PURGE" = 1 ]; then
    step "Purging machine state (loaner hygiene)"
    if have tmux; then
      tmux ls -F '#S' 2>/dev/null | grep '^agentdeck_' | while read -r s; do run tmux kill-session -t "$s"; done || true
    fi
    if is_macos; then
      for p in "$HOME"/Library/LaunchAgents/com.agentdeck.*.plist; do
        [ -e "$p" ] || continue
        run launchctl unload "$p" 2>/dev/null || true; run rm -f "$p"
      done
    fi
    run rm -rf "$HOME/.agent-deck" "$HOME/.config/agent-deck" "$HOME/.local/share/agent-deck" "$HOME/.cache/agent-deck"
    have gh && run gh auth logout --hostname github.com 2>/dev/null <<<"Y" || true
    if have claude; then
      note "claude: run /logout inside claude, or delete the 'Claude Code-credentials' keychain item"
    fi
    run rm -f "$HOME/.claude/.credentials.json"
    is_macos && run security delete-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 || true
    run rm -rf "${AGENTOS_STATE_DIR:-$HOME/.local/state/agentos}"
    note "Homebrew packages were left installed. Remove with: brew bundle cleanup --force --file=$AGENTOS_REPO/Brewfile (careful: removes everything not listed)"
  fi
  ok "uninstall complete"
}

RC_BEGIN="# >>> agentos >>>"
RC_END="# <<< agentos <<<"
sed_rc_block() {
  local mode="$1" rc
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [ "$mode" = remove ]; then
      [ -f "$rc" ] && grep -qF "$RC_BEGIN" "$rc" || continue
      if [ "$DRY_RUN" = 1 ]; then note "[dry-run] strip agentos block from $rc"; continue; fi
      awk -v b="$RC_BEGIN" -v e="$RC_END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$rc" >"$rc.tmp" && mv "$rc.tmp" "$rc"
      ok "cleaned ${rc/#$HOME/~}"
    fi
  done
}

if [ "$UNINSTALL" = 1 ]; then do_uninstall; exit 0; fi

# ────────────────────────────────────────────────────────────────────────────
# 1. Packages
# ────────────────────────────────────────────────────────────────────────────
install_packages_macos() {
  if ! have brew; then
    step "Installing Homebrew (installs Xcode Command Line Tools; asks for your password once)"
    run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
    [ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)"
  fi
  step "brew bundle"
  HOMEBREW_NO_AUTO_UPDATE=0 run brew bundle --file="$AGENTOS_REPO/Brewfile"
}

install_agent_deck_release() {
  local v="$AGENT_DECK_VERSION" os arch url tmp
  if have agent-deck && [ "$(agent-deck --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" = "$v" ]; then
    ok "agent-deck $v already installed"; return 0
  fi
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) die "unsupported arch $(uname -m)" ;; esac
  url="https://github.com/asheshgoplani/agent-deck/releases/download/v$v/agent-deck_${v}_${os}_${arch}.tar.gz"
  step "agent-deck $v from GitHub release"
  if [ "$DRY_RUN" = 1 ]; then note "[dry-run] curl $url"; return 0; fi
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/ad.tgz" || die "download failed: $url"
  tar -xzf "$tmp/ad.tgz" -C "$tmp" agent-deck
  mkdir -p "$BIN_DIR"; install -m 0755 "$tmp/agent-deck" "$BIN_DIR/agent-deck"; rm -rf "$tmp"
  ok "installed $BIN_DIR/agent-deck"
}

install_packages_linux() {
  step "apt packages"
  if have apt-get; then
    local pkgs=(git tmux jq curl ca-certificates nodejs npm ripgrep fd-find)
    local missing=()
    for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
    if [ ${#missing[@]} -gt 0 ]; then
      run sudo_if_needed apt-get update -qq
      run sudo_if_needed env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    else ok "apt packages present"; fi
  else
    warn "no apt-get; install git tmux jq curl node/npm yourself"
  fi
  install_agent_deck_release
  if ! have claude; then
    step "Claude Code (npm)"
    run npm install -g --prefix "$HOME/.local" @anthropic-ai/claude-code
  else ok "claude $(claude --version 2>/dev/null | head -1)"; fi
}

if [ "$PACKAGES" = 1 ]; then
  if is_macos; then install_packages_macos; else install_packages_linux; fi
fi

# ────────────────────────────────────────────────────────────────────────────
# 2. Version gate
# ────────────────────────────────────────────────────────────────────────────
step "Version check"
if have agent-deck; then
  ADV="$(agent-deck --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if version_ge "$ADV" "$AGENT_DECK_MIN"; then ok "agent-deck $ADV (>= $AGENT_DECK_MIN)"
  else die "agent-deck $ADV is older than $AGENT_DECK_MIN; run: brew upgrade agent-deck"; fi
else
  [ "$DRY_RUN" = 1 ] && warn "agent-deck not installed (dry-run)" || die "agent-deck not installed"
fi
if have claude; then ok "claude $(claude --version 2>/dev/null | head -1)"; else warn "claude not on PATH yet"; fi

# ────────────────────────────────────────────────────────────────────────────
# 3. Dotfiles
# ────────────────────────────────────────────────────────────────────────────
step "agentos CLI"
link "$AGENTOS_REPO/bin/agentos" "$BIN_DIR/agentos"
link "$AGENTOS_REPO/bin/agentos-conductor-hook" "$BIN_DIR/agentos-conductor-hook"

for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  # zsh is the macOS default; add to .bashrc only if it already exists.
  case "$rc" in *.bashrc) [ -f "$rc" ] || continue ;; esac
  if ! grep -qF "$RC_BEGIN" "$rc" 2>/dev/null; then
    if [ "$DRY_RUN" = 1 ]; then note "[dry-run] add PATH block to $rc"; else
      { printf '\n%s\n' "$RC_BEGIN"
        printf 'export PATH="$HOME/.local/bin:$PATH"\n'
        printf '[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"\n'
        printf 'alias ad=agent-deck\n'
        printf '%s\n' "$RC_END"; } >>"$rc"
      ok "PATH block added to ${rc/#$HOME/~}"
    fi
  else note "rc block present in ${rc/#$HOME/~}"; fi
done

step "Ghostty"
link "$AGENTOS_REPO/ghostty/config" "$HOME/.config/ghostty/config"

step "agent-deck config"
render "$AGENTOS_REPO/agent-deck/config.toml" "$HOME/.config/agent-deck/config.toml"
if [ -f "$HOME/.agent-deck/config.toml" ]; then
  note "legacy ~/.agent-deck/config.toml is shadowed by the XDG config (left in place)"
fi

step "Claude Code"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
run mkdir -p "$CLAUDE_DIR"
# settings.json is MERGED, not linked: agent-deck (and Claude itself) write their own
# hook/permission entries into it, and those must not end up in the repo.
S="$CLAUDE_DIR/settings.json"
if [ "$DRY_RUN" = 1 ]; then note "[dry-run] merge claude/settings.base.json into $S"
else
  [ -f "$S" ] && ! jq -e . "$S" >/dev/null 2>&1 && backup_path "$S"
  [ -f "$S" ] || echo '{}' >"$S"
  jq -S -s '
    def uniq_arr: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);
    .[0] as $cur | .[1] as $base
    | $cur * ($base | del(.permissions))
    | .permissions.allow = (((($cur.permissions.allow // []) + ($base.permissions.allow // []))) | uniq_arr)
    | .permissions.deny  = (((($cur.permissions.deny  // []) + ($base.permissions.deny  // []))) | uniq_arr)
  ' "$S" "$AGENTOS_REPO/claude/settings.base.json" >"$S.tmp" && mv "$S.tmp" "$S"
  ok "merged settings.json"
fi
[ -f "$AGENTOS_REPO/claude/CLAUDE.md" ] && link "$AGENTOS_REPO/claude/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
for sub in skills commands agents hooks; do
  for item in "$AGENTOS_REPO/claude/$sub"/*; do
    [ -e "$item" ] || continue
    case "$(basename "$item")" in .gitkeep|README.md) continue ;; esac
    link "$item" "$CLAUDE_DIR/$sub/$(basename "$item")"
  done
done

# ────────────────────────────────────────────────────────────────────────────
# 4. Conductors
# ────────────────────────────────────────────────────────────────────────────
if [ "$CONDUCTORS" = 1 ]; then
  step "Conductors"
  CDIR="$AGENTOS_REPO/agent-deck/conductor"
  while IFS='|' read -r name desc; do
    case "$name" in ''|\#*) continue ;; esac
    args=(conductor setup "$name" --json --description "$desc"
          --shared-policy-md "$CDIR/POLICY.md")
    [ -f "$CDIR/$name/CLAUDE.md" ] && args+=(--claude-md "$CDIR/$name/CLAUDE.md")
    [ -f "$CDIR/$name/POLICY.md" ] && args+=(--policy-md "$CDIR/$name/POLICY.md")
    if [ "$DRY_RUN" = 1 ]; then note "[dry-run] agent-deck ${args[*]}"; continue; fi
    if out="$(agent-deck "${args[@]}" </dev/null 2>&1)"; then
      ok "conductor $name set up"
    else
      # Heartbeat daemons need launchd (macOS) or systemd --user (Linux). Containers have neither;
      # the conductor still works (heartbeats can be driven by `agentos` or cron).
      warn "conductor setup $name: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"
    fi
    d="$CONDUCTOR_ROOT/$name"
    if [ -d "$d" ]; then
      mkdir -p "$d/.claude"
      [ -f "$d/.claude/settings.json" ] || echo '{}' >"$d/.claude/settings.json"
      # Merge our hooks next to agent-deck's managed permission policy (it preserves unknown keys).
      jq -S -s '
        .[0] as $cur | .[1] as $add
        | $cur | .hooks = (($cur.hooks // {}) as $h
            | reduce ($add.hooks | keys[]) as $k ($h;
                .[$k] = ((.[$k] // []) | map(select((.hooks // []) | all(.command | test("agentos-conductor-hook") | not))))
                        + $add.hooks[$k]))
      ' "$d/.claude/settings.json" "$CDIR/claude-hooks.json" >"$d/.claude/settings.json.tmp" \
        && mv "$d/.claude/settings.json.tmp" "$d/.claude/settings.json"
      ok "conductor $name: agentos hooks wired"
      manifest_add "conductor	$name"
    fi
  done <"$CDIR/conductors.conf"
fi

# ────────────────────────────────────────────────────────────────────────────
# 5. Next steps
# ────────────────────────────────────────────────────────────────────────────
step "Done"
cat <<EOF
  Next (one-time, needs a browser):
    1. exec \$SHELL -l            # pick up PATH
    2. claude                     # log in, then /exit
    3. gh auth login              # optional; needed for PR flows
    4. agent-deck                 # accept the "install Claude hooks" prompt
    5. agent-deck session start conductor-fleet-spawner
    6. agentos doctor
EOF
