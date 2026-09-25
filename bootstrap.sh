#!/usr/bin/env bash
# One-liner entry point for a fresh machine:
#   curl -fsSL https://raw.githubusercontent.com/<you>/agentos/main/bootstrap.sh | bash
# Installs Homebrew (which brings git via the Xcode CLT) if needed, clones the repo,
# then runs ./install.sh. Extra args are passed through: ... | bash -s -- --no-conductors
set -euo pipefail

# Set this once to your fork, or override with AGENTOS_GIT_URL=... at run time.
AGENTOS_GIT_URL="${AGENTOS_GIT_URL:-https://github.com/CHANGE-ME/agentos.git}"
AGENTOS_DIR="${AGENTOS_DIR:-$HOME/agentos}"

case "$AGENTOS_GIT_URL" in *CHANGE-ME*) echo "Set AGENTOS_GIT_URL (or edit bootstrap.sh)"; exit 1 ;; esac

if [ "$(uname -s)" = Darwin ] && ! command -v brew >/dev/null 2>&1 && ! [ -x /opt/homebrew/bin/brew ]; then
  echo "==> Installing Homebrew (you'll be asked for your password once)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
[ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)"

if [ -d "$AGENTOS_DIR/.git" ]; then
  git -C "$AGENTOS_DIR" pull --ff-only
else
  git clone --depth 1 "$AGENTOS_GIT_URL" "$AGENTOS_DIR"
fi
exec "$AGENTOS_DIR/install.sh" "$@"
