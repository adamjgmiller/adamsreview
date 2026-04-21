#!/usr/bin/env bash
# uninstall.sh — reverse scripts/install.sh.
#
# Removes the five symlinks created under ~/.claude/commands/ (only if
# they still point into this repo) and reverses the $HOME/ →
# /Users/adammiller/ path substitution in the four command files.
#
# Idempotent. No-op on path substitution for the maintainer.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMANDS_DIR="$HOME/.claude/commands"
CANONICAL_PREFIX="/Users/adammiller/"

# --- Remove symlinks only if they point into this repo ---------------------
remove_link() {
  local link="$1" expected="$2"
  if [ ! -L "$link" ]; then
    return 0
  fi
  local target
  target="$(readlink "$link")"
  if [ "$target" = "$expected" ]; then
    rm "$link"
    echo "Removed $link"
  else
    echo "Skipped $link (points to $target, not this repo)"
  fi
}

remove_link "$COMMANDS_DIR/_shared" "$REPO_ROOT/commands/_shared"
for cmd in adams-review adams-review-fix adams-review-walkthrough adams-review-promote adams-review-add; do
  remove_link "$COMMANDS_DIR/$cmd.md" "$REPO_ROOT/commands/$cmd.md"
done

# --- Reverse path substitution ---------------------------------------------
if [ "$HOME" = "/Users/adammiller" ]; then
  echo "(maintainer uninstall — no path substitution to reverse)"
else
  echo "Reversing ${HOME}/ → ${CANONICAL_PREFIX} in command files..."
  for f in "$REPO_ROOT"/commands/adams-review*.md; do
    sed "s|${HOME}/|${CANONICAL_PREFIX}|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
fi

echo "Done. Working tree reverted to committed form."
