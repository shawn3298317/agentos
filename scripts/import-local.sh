#!/usr/bin/env bash
# Pull this machine's Claude Code customisations into the repo so a fresh machine gets them.
# Run on your main machine, review `git diff`, commit. Re-run any time.
#
#   scripts/import-local.sh            copy + secret scan (aborts on hits)
#   scripts/import-local.sh --force    copy even if the scan finds something (you'll review)
#
# Imports: ~/.claude/CLAUDE.md, ~/.claude/{skills,commands,agents}/*, your own ~/.claude/hooks/*,
#          ~/.config/ghostty/config
# Never imports: credentials, settings.json (agent-deck writes into it), projects/, todos/,
#          statsig/, shell-snapshots/, plugins/ (reinstall plugins from their marketplace instead),
#          or hook scripts owned by agent-deck/herdr.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$REPO/lib/common.sh"
FORCE=0; [ "${1:-}" = --force ] && FORCE=1
SRC="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DST="$REPO/claude"

points_into_repo() { [ -L "$1" ] && case "$(readlink "$1")" in "$REPO"/*) return 0;; esac; return 1; }

copy_item() { # src dst
  if points_into_repo "$1"; then note "skip (already managed) ${1/#$HOME/~}"; return; fi
  rm -rf "$2"; mkdir -p "$(dirname "$2")"
  cp -RL "$1" "$2"; ok "imported ${1/#$HOME/~}"
}

step "Claude Code → $DST"
[ -f "$SRC/CLAUDE.md" ] && copy_item "$SRC/CLAUDE.md" "$DST/CLAUDE.md"
for sub in skills commands agents; do
  [ -d "$SRC/$sub" ] || continue
  for item in "$SRC/$sub"/*; do [ -e "$item" ] && copy_item "$item" "$DST/$sub/$(basename "$item")"; done
done
if [ -d "$SRC/hooks" ]; then
  for item in "$SRC/hooks"/*; do
    [ -e "$item" ] || continue
    case "$(basename "$item")" in *agent-deck*|*agentdeck*|*herdr*) note "skip tool-owned hook $(basename "$item")"; continue ;; esac
    copy_item "$item" "$DST/hooks/$(basename "$item")"
  done
fi
if [ -f "$SRC/settings.json" ]; then
  note "settings.json NOT imported; your custom (non agent-deck) hooks/permissions are listed below."
  note "Copy the ones you want into claude/settings.base.json:"
  jq '{permissions: .permissions, hooks: (.hooks // {} | with_entries(.value |= map(select((.hooks // []) | all(.command | test("agent-deck|herdr") | not)))) | with_entries(select(.value | length > 0)))}' "$SRC/settings.json" 2>/dev/null | sed 's/^/    /' || true
fi

step "Ghostty"
G="$HOME/.config/ghostty/config"
if [ -f "$G" ] && ! points_into_repo "$G"; then
  if cmp -s "$G" "$REPO/ghostty/config"; then note "ghostty config identical"; else
    diff -u "$REPO/ghostty/config" "$G" | head -40 || true
    cp "$G" "$REPO/ghostty/config"; ok "imported ghostty config (the repo copy had agentos keybinds; re-add them if you want them)"
  fi
fi

step "Secret scan"
PAT='(sk-ant-[A-Za-z0-9_-]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(api[_-]?key|secret|token|password)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'$]{12,})'
if hits="$(grep -rEnI "$PAT" "$DST" "$REPO/ghostty" 2>/dev/null)"; then
  err "possible secrets:"; printf '%s\n' "$hits" | sed 's/^/    /' | cut -c1-200
  [ "$FORCE" = 1 ] || die "aborting; remove them (or re-run with --force and scrub before committing)"
else ok "no secrets found"; fi

step "Next"
note "git -C $REPO status && git -C $REPO diff"
note "then ./install.sh --no-packages   (replaces the originals with symlinks into the repo; originals are backed up)"
