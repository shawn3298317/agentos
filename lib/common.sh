# shellcheck shell=bash
# Shared helpers for install.sh / uninstall / scripts. Sourced, not executed.

AGENTOS_MANIFEST="${AGENTOS_STATE_DIR:-$HOME/.local/state/agentos}/manifest"
AGENTOS_BACKUP_DIR="${AGENTOS_STATE_DIR:-$HOME/.local/state/agentos}/backups"

if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
  C_B=; C_G=; C_Y=; C_R=; C_D=; C_0=
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_B" "$C_0" "$C_B" "$*" "$C_0"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '  %s✗%s %s\n' "$C_R" "$C_0" "$*" >&2; }
note() { printf '  %s%s%s\n' "$C_D" "$*" "$C_0"; }
die()  { err "$*"; exit 1; }

is_macos() { [ "$(uname -s)" = "Darwin" ]; }
have()     { command -v "$1" >/dev/null 2>&1; }

# run CMD... — honours DRY_RUN=1
run() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '  %s[dry-run]%s %s\n' "$C_D" "$C_0" "$*"
    return 0
  fi
  "$@"
}

manifest_add() {
  [ "${DRY_RUN:-0}" = 1 ] && return 0
  mkdir -p "$(dirname "$AGENTOS_MANIFEST")"
  grep -qxF "$1" "$AGENTOS_MANIFEST" 2>/dev/null || printf '%s\n' "$1" >>"$AGENTOS_MANIFEST"
}

# backup_path PATH — move an existing non-managed file aside (once).
backup_path() {
  local p="$1" rel dst
  [ -e "$p" ] || [ -L "$p" ] || return 0
  rel="${p#"$HOME"/}"
  dst="$AGENTOS_BACKUP_DIR/$rel"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    dst="$dst.$(date +%Y%m%d%H%M%S)"
  fi
  run mkdir -p "$(dirname "$dst")"
  run mv "$p" "$dst"
  note "backed up $p -> $dst"
  manifest_add "backup	$p	$dst"
}

# link SRC DST — idempotent symlink; backs up whatever was there.
link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    note "linked  ${dst/#$HOME/~}"
    manifest_add "link	$dst	$src"
    return 0
  fi
  backup_path "$dst"
  run mkdir -p "$(dirname "$dst")"
  run ln -s "$src" "$dst"
  ok "linked  ${dst/#$HOME/~} -> ${src/#$HOME/~}"
  manifest_add "link	$dst	$src"
}

# render SRC DST — copy a template, substituting __HOME__ / __REPO__ / __USER__.
# Leaves DST alone if it already matches; backs up if it differs.
render() {
  local src="$1" dst="$2" tmp
  tmp="$(mktemp)"
  sed -e "s|__HOME__|$HOME|g" -e "s|__REPO__|$AGENTOS_REPO|g" -e "s|__USER__|${USER:-$(id -un)}|g" "$src" >"$tmp"
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"; note "current ${dst/#$HOME/~}"
    manifest_add "file	$dst"
    return 0
  fi
  backup_path "$dst"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '  %s[dry-run]%s render %s -> %s\n' "$C_D" "$C_0" "$src" "$dst"; rm -f "$tmp"; return 0
  fi
  mkdir -p "$(dirname "$dst")"
  mv "$tmp" "$dst"
  ok "wrote   ${dst/#$HOME/~}"
  manifest_add "file	$dst"
}

# version_ge A B — true if semver A >= B
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}
