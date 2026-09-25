#!/usr/bin/env bash
# End-to-end test of the one-command install on a fresh machine (run inside test/Dockerfile).
# Everything real except what needs a GUI, launchd/systemd, or a logged-in Claude account.
set -uo pipefail
REPO="$HOME/agentos"
PASS=0; FAIL=0
t()  { if eval "$2" >/dev/null 2>&1; then printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); else printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
hdr() { printf '\n\033[1m## %s\033[0m\n' "$*"; }
export PATH="$HOME/.local/bin:$PATH"

hdr "0. Fresh machine"
t "no git"        "! command -v git"
t "no jq"         "! command -v jq"
t "no agent-deck" "! command -v agent-deck"
t "no claude"     "! command -v claude"
# Pre-existing user files that install must back up and uninstall must restore.
mkdir -p ~/.config/ghostty ~/.claude
echo "# ORIGINAL ghostty" > ~/.config/ghostty/config
echo '{"permissions":{"allow":["Bash(make test)"]},"model":"opus"}' > ~/.claude/settings.json
touch ~/.bashrc

hdr "1. Dry run changes nothing"
before="$(find ~ -path ~/agentos -prune -o -print | sort | md5sum)"
"$REPO/install.sh" --dry-run --no-packages >/tmp/dry.log 2>&1; rc=$?
t "dry-run exits 0 (no packages yet, agent-deck missing is a warning)" "[ $rc = 0 ]"
after="$(find ~ -path ~/agentos -prune -o -print | sort | md5sum)"
t "dry-run left \$HOME untouched" "[ '$before' = '$after' ]"

hdr "2. One-command install"
start=$(date +%s)
"$REPO/install.sh" >/tmp/install1.log 2>&1; rc=$?
dur=$(( $(date +%s) - start ))
tail -n 25 /tmp/install1.log | sed 's/^/    /'
t "install.sh exits 0 (${dur}s)" "[ $rc = 0 ]"
. "$REPO/versions.env"
t "agent-deck == pinned $AGENT_DECK_VERSION" "agent-deck --version | grep -q '$AGENT_DECK_VERSION'"
t "claude installed" "claude --version"
t "git/tmux/jq installed" "command -v git && command -v tmux && command -v jq"
t "agentos CLI linked" "[ \"\$(readlink ~/.local/bin/agentos)\" = '$REPO/bin/agentos' ]"
t "PATH block in .bashrc" "grep -q '>>> agentos >>>' ~/.bashrc"
t "ghostty config linked to repo" "[ \"\$(readlink ~/.config/ghostty/config)\" = '$REPO/ghostty/config' ]"
t "original ghostty config backed up" "grep -rq ORIGINAL ~/.local/state/agentos/backups/.config/ghostty/"
t "agent-deck XDG config rendered" "[ -f ~/.config/agent-deck/config.toml ] && ! grep -q __HOME__ ~/.config/agent-deck/config.toml"
t "agent-deck accepts config" "agent-deck conductor list --json"
t "settings.json kept user entries" "jq -e '.model==\"opus\" and (.permissions.allow | index(\"Bash(make test)\"))' ~/.claude/settings.json"
t "settings.json got agentos entries" "jq -e '.permissions.allow | index(\"Bash(agent-deck status *)\")' ~/.claude/settings.json"
t "settings.json deny list merged" "jq -e '.permissions.deny | index(\"Read(./.env)\")' ~/.claude/settings.json"
for c in fleet-spawner reviewer; do
  d=~/.agent-deck/conductor/$c
  t "conductor $c: dir + meta.json" "jq -e '.name==\"$c\"' $d/meta.json"
  t "conductor $c: CLAUDE.md -> repo" "[ \"\$(readlink $d/CLAUDE.md)\" = '$REPO/agent-deck/conductor/$c/CLAUDE.md' ]"
  t "conductor $c: agent-deck permission policy kept" "jq -e '.permissions.allow | length > 0' $d/.claude/settings.json"
  t "conductor $c: agentos hooks wired (4 events)" "jq -e '[.hooks.SessionStart, .hooks.UserPromptSubmit, .hooks.Stop, .hooks.SessionEnd] | all(length==1)' $d/.claude/settings.json"
  t "conductor $c: registered as agent-deck session" "agent-deck session show conductor-$c --json"
done
t "shared POLICY.md -> repo" "[ \"\$(readlink ~/.agent-deck/conductor/POLICY.md)\" = '$REPO/agent-deck/conductor/POLICY.md' ] || cmp -s ~/.agent-deck/conductor/POLICY.md '$REPO/agent-deck/conductor/POLICY.md'"

hdr "3. Idempotent re-run"
snap() { for f in ~/.config/agent-deck/config.toml ~/.claude/settings.json ~/.agent-deck/conductor/*/.claude/settings.json ~/.bashrc; do md5sum "$f"; done; ls -R ~/.local/state/agentos/backups | md5sum; }
s1="$(snap)"
"$REPO/install.sh" >/tmp/install2.log 2>&1; rc=$?
s2="$(snap)"
t "second run exits 0" "[ $rc = 0 ]"
t "second run changed nothing (configs, hooks, rc, backups)" "[ \"\$s1\" = \"\$s2\" ]"
t "manifest has no duplicates" "[ \$(sort ~/.local/state/agentos/manifest | uniq -d | wc -l) = 0 ]"

hdr "4. agentos doctor"
agentos doctor >/tmp/doctor.log 2>&1; rc=$?
sed 's/^/    /' /tmp/doctor.log
t "doctor: no hard failures" "[ $rc = 0 ]"

hdr "5. Conductor state hook"
H=~/.local/bin/agentos-conductor-hook
D=~/.agent-deck/conductor/fleet-spawner
cd "$D"
out="$(jq -n --arg c "$D" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}' | $H)"
t "SessionStart emits additionalContext" "printf '%s' '$(printf '%s' "$out" | base64 -w0)' | base64 -d | jq -e '.hookSpecificOutput.additionalContext | contains(\"state.json\")'"
t "state.json bootstrapped with fleet snapshot" "jq -e '.conductor==\"fleet-spawner\" and (.fleet.counts|type==\"object\")' $D/state.json"
t "task-log.md bootstrapped" "[ -f $D/task-log.md ]"
sleep 1
jq -n --arg c "$D" '{hook_event_name:"UserPromptSubmit",prompt:"[HEARTBEAT] check",cwd:$c}' | $H
t "heartbeat prompt recorded in state.json" "jq -e '.last_heartbeat != null' $D/state.json"
sleep 1
out="$(jq -n --arg c "$D" '{hook_event_name:"Stop",stop_hook_active:false,cwd:$c}' | $H)"
t "Stop blocks when task-log not updated" "printf '%s' '$out' | jq -e '.decision==\"block\"'"
out="$(jq -n --arg c "$D" '{hook_event_name:"Stop",stop_hook_active:true,cwd:$c}' | $H)"
t "Stop never blocks twice (stop_hook_active)" "[ -z '$out' ]"
sleep 1; printf '## now - test\n- did a thing\n' >>"$D/task-log.md"
out="$(jq -n --arg c "$D" '{hook_event_name:"Stop",stop_hook_active:false,cwd:$c}' | $H)"
t "Stop passes after task-log append" "[ -z '$out' ]"
t "events.jsonl written" "[ \$(wc -l < $D/events.jsonl) -ge 3 ]"
printf '\n### [20260925-001] test learning\n- **Type**: pattern\n- **Status**: active\n\n### [20260925-002] old\n- **Status**: retired\n' >>"$D/LEARNINGS.md"
out="$(jq -n --arg c "$D" '{hook_event_name:"SessionStart",source:"compact",cwd:$c}' | $H | jq -r .hookSpecificOutput.additionalContext)"
t "SessionStart injects active learnings" "printf '%s' \"\$out\" | grep -q 'test learning'"
t "SessionStart skips retired learnings" "! printf '%s' \"\$out\" | grep -q '002\\] old'"
t "SessionStart injects task-log tail" "printf '%s' \"\$out\" | grep -q 'did a thing'"
echo '{broken' > "$D/state.json"
jq -n --arg c "$D" '{hook_event_name:"SessionStart",source:"resume",cwd:$c}' | $H >/dev/null
t "corrupt state.json is quarantined + rebuilt" "jq -e . $D/state.json && ls $D/.agentos/state.json.corrupt.*"
cd ~

hdr "6. Worktree session (branch naming)"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main
mkdir -p ~/src/demo && cd ~/src/demo && git init -q && echo hi > README.md && git add . && git commit -qm init
agent-deck add ~/src/demo -c claude -w deck/demo-task -b -t demo-task -g demo --json >/tmp/wt.json 2>&1
t "agent-deck add -w deck/<slug> -b succeeds" "jq -e .worktree_path /tmp/wt.json"
t "branch is exactly deck/demo-task (no prefix)" "git -C ~/src/demo branch --list 'deck/demo-task' | grep -q demo-task"
t "worktree under <repo>/.worktrees/" "jq -r .worktree_path /tmp/wt.json | grep -q '/src/demo/.worktrees/'"
t "tracked by worktree info" "agent-deck worktree info demo-task --json"
cd ~

hdr "7. migrate-local re-adopts an untracked worktree session"
git -C ~/src/demo worktree add -q ~/src/demo/.worktrees/deck-legacy -b deck/legacy
agent-deck add ~/src/demo/.worktrees/deck-legacy -c claude -t legacy-sess -g demo --no-parent --json >/dev/null 2>&1
t "precondition: legacy session has no worktree metadata" "! agent-deck worktree info legacy-sess --json 2>/dev/null | jq -e '.worktree_branch // .branch // empty' | grep -q ."
"$REPO/scripts/migrate-local.sh" --yes >/tmp/migrate.log 2>&1; rc=$?
tail -n 12 /tmp/migrate.log | sed 's/^/    /'
t "migrate-local exits 0" "[ $rc = 0 ]"
t "legacy-sess now tracked as worktree on deck/legacy" "agent-deck worktree info legacy-sess --json | grep -q 'deck/legacy'"
t "legacy worktree dir still there" "[ -f ~/src/demo/.worktrees/deck-legacy/README.md ]"
t "snapshot tarball written" "ls ~/agent-deck-snapshot-*.tgz"

hdr "8. Uninstall --purge (loaner hygiene)"
"$REPO/install.sh" --uninstall --purge >/tmp/uninstall.log 2>&1; rc=$?
tail -n 15 /tmp/uninstall.log | sed 's/^/    /'
t "uninstall exits 0" "[ $rc = 0 ]"
t "original ghostty config restored" "grep -q ORIGINAL ~/.config/ghostty/config && [ ! -L ~/.config/ghostty/config ]"
t "agentos links removed" "[ ! -e ~/.local/bin/agentos ]"
t "PATH block removed from .bashrc" "! grep -q 'agentos' ~/.bashrc"
t "agent-deck state purged" "[ ! -e ~/.agent-deck ] && [ ! -e ~/.config/agent-deck ]"
t "no agentdeck tmux sessions left" "! tmux ls 2>/dev/null | grep -q agentdeck_"
# (agent-deck may normalise "model" to e.g. "opus[1m]"; that's agent-deck's doing, not ours)
t "user's own settings.json entries survive" "jq -e '(.model|startswith(\"opus\")) and (.permissions.allow | index(\"Bash(make test)\"))' ~/.claude/settings.json"

hdr "Result"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
