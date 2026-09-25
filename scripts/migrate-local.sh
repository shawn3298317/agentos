#!/usr/bin/env bash
# One-time migration of the ORIGINAL machine (agent-deck 0.27.x) onto agentos.
# Not needed on a fresh machine; install.sh covers that case.
#
#   scripts/migrate-local.sh           interactive (asks before each change)
#   scripts/migrate-local.sh --yes     no prompts
#
# What it does:
#   1. snapshots ~/.agent-deck (tarball) before touching anything
#   2. brew bundle → agent-deck >= AGENT_DECK_MIN (0.27 → 1.16 fixes the heartbeat daemon,
#      truthful send exit codes, pricing, session children --follow, recall)
#   3. install.sh --no-packages → XDG config, conductors re-set-up from the repo
#      (installs the launchd heartbeat plists) + agentos state hooks
#   4. restarts conductors in error state (conductor-reviewer)
#   5. re-adopts sessions that live in a .worktrees/ path but have no worktree
#      metadata (learning-lc-sep), resuming the same Claude conversation
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$REPO/lib/common.sh"
# shellcheck source=../versions.env
. "$REPO/versions.env"

YES=0; [ "${1:-}" = --yes ] && YES=1
confirm() { [ "$YES" = 1 ] && return 0; read -r -p "  $1 [y/N] " a </dev/tty; [[ "$a" =~ ^[Yy] ]]; }

step "1. Snapshot ~/.agent-deck"
SNAP="$HOME/agent-deck-snapshot-$(date +%Y%m%d%H%M%S).tgz"
tar -czf "$SNAP" -C "$HOME" .agent-deck --exclude '.agent-deck/logs' --exclude '*.log.gz' 2>/dev/null || true
ok "snapshot: $SNAP"

step "2. Upgrade agent-deck"
if is_macos; then brew bundle --file="$REPO/Brewfile"; brew upgrade asheshgoplani/tap/agent-deck || true; fi
V="$(agent-deck --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
version_ge "$V" "$AGENT_DECK_MIN" || die "agent-deck $V < $AGENT_DECK_MIN after upgrade"
ok "agent-deck $V"

step "3. install.sh --no-packages"
"$REPO/install.sh" --no-packages

step "4. Restart conductors in error state"
for s in $(agent-deck list --json 2>/dev/null | jq -r '.[] | select(.status=="error") | .title' 2>/dev/null); do
  if confirm "restart '$s' (status=error)?"; then agent-deck session restart "$s" && ok "restarted $s" || warn "restart $s failed"; fi
done

step "5. Re-adopt untracked worktree sessions"
agent-deck list --json 2>/dev/null | jq -c '.[] | select((.path // "") | test("/\\.worktrees/"))' | while read -r row; do
  title="$(jq -r .title <<<"$row")"
  info="$(agent-deck worktree info "$title" --json 2>/dev/null || true)"
  if [ -n "$(jq -r '.worktree_path // .path // empty' <<<"$info" 2>/dev/null)" ] && jq -e '.worktree_branch // .branch' <<<"$info" >/dev/null 2>&1; then
    note "$title: already tracked as a worktree"; continue
  fi
  show="$(agent-deck session show "$title" --json)"
  path="$(jq -r .path <<<"$show")"; group="$(jq -r .group <<<"$show")"; csid="$(jq -r '.claude_session_id // empty' <<<"$show")"; parent="$(jq -r '.parent_session_id // empty' <<<"$show")"
  [ -d "$path" ] || { warn "$title: $path missing, skipping"; continue; }
  branch="$(git -C "$path" rev-parse --abbrev-ref HEAD)"
  repo="$(git -C "$path" rev-parse --path-format=absolute --git-common-dir | sed 's|/\.git$||')"
  echo "  $title: path=$path branch=$branch repo=$repo group=$group claude_session=$csid"
  if confirm "re-register '$title' as a tracked worktree session (keeps the worktree, resumes the conversation)?"; then
    agent-deck session stop "$title" >/dev/null 2>&1 || true
    agent-deck remove "$title" >/dev/null   # registry only; auto_cleanup=false and no worktree metadata → dir untouched
    [ -d "$path" ] || die "$path disappeared after remove; restore from $SNAP"
    args=(add "$repo" -c claude -w "$branch" -t "$title" -g "$group")
    if [ -n "$parent" ]; then args+=(--parent "$parent"); else args+=(--no-parent); fi
    [ -n "$csid" ] && args+=(--resume-session "$csid")
    agent-deck "${args[@]}" && ok "$title re-adopted (reuses existing worktree for $branch)"
  fi
done

step "6. Health"
"$REPO/bin/agentos" doctor || true
note "Old per-conductor files are in $SNAP and in ~/.local/state/agentos/backups/."
