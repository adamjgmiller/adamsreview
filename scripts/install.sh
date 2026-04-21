#!/usr/bin/env bash
# install.sh — set up adams-review slash commands for Claude Code.
#
# Substitutes /Users/adammiller/ → $HOME/ in the four top-level command
# files' allowed-tools: YAML, and creates five symlinks into
# ~/.claude/commands/ so Claude Code discovers the slash commands.
#
# Idempotent. Uninstall with scripts/uninstall.sh. See README Installation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMANDS_DIR="$HOME/.claude/commands"
CANONICAL_PREFIX="/Users/adammiller/"

# --- Preflight: required tools ---------------------------------------------
missing=()
for tool in uv jq gh git; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: missing required tool(s): ${missing[*]}" >&2
  echo "Action: install them before re-running (see README § Dependencies)." >&2
  echo "  macOS:  brew install ${missing[*]}" >&2
  echo "  Linux:  use your distro's package manager" >&2
  exit 5
fi

# --- Path substitution -----------------------------------------------------
if [ "$HOME" = "/Users/adammiller" ]; then
  echo "(maintainer install — no path substitution needed; working tree stays clean)"
else
  echo "Substituting ${CANONICAL_PREFIX} → ${HOME}/ in command files..."
  for f in "$REPO_ROOT"/commands/adams-review*.md; do
    sed "s|${CANONICAL_PREFIX}|${HOME}/|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
fi

# --- Symlinks --------------------------------------------------------------
mkdir -p "$COMMANDS_DIR"
ln -sfn "$REPO_ROOT/commands/_shared" "$COMMANDS_DIR/_shared"
for cmd in adams-review adams-review-fix adams-review-walkthrough adams-review-promote adams-review-add; do
  ln -sfn "$REPO_ROOT/commands/$cmd.md" "$COMMANDS_DIR/$cmd.md"
done

# --- Verify ----------------------------------------------------------------
shared_link="$(readlink "$COMMANDS_DIR/_shared")"
if [ "$shared_link" != "$REPO_ROOT/commands/_shared" ]; then
  echo "ERROR: _shared symlink verification failed" >&2
  echo "  expected: $REPO_ROOT/commands/_shared" >&2
  echo "  actual:   $shared_link" >&2
  exit 4
fi
if ! grep -q "${HOME}/.claude/commands/_shared/tools" "$REPO_ROOT/commands/adams-review.md"; then
  echo "ERROR: path substitution verification failed in commands/adams-review.md" >&2
  echo "Action: inspect the file and re-run, or run scripts/uninstall.sh to revert." >&2
  exit 4
fi

# --- Next steps ------------------------------------------------------------
cat <<EOF

Installed:
  $COMMANDS_DIR/_shared                      -> $REPO_ROOT/commands/_shared
  $COMMANDS_DIR/adams-review.md              -> $REPO_ROOT/commands/adams-review.md
  $COMMANDS_DIR/adams-review-fix.md          -> $REPO_ROOT/commands/adams-review-fix.md
  $COMMANDS_DIR/adams-review-walkthrough.md  -> $REPO_ROOT/commands/adams-review-walkthrough.md
  $COMMANDS_DIR/adams-review-promote.md      -> $REPO_ROOT/commands/adams-review-promote.md
  $COMMANDS_DIR/adams-review-add.md          -> $REPO_ROOT/commands/adams-review-add.md

Next steps:
  1. Verify: bash test/smoke.sh    (expect "smoke: PASS (…)")
  2. Try /adams-review in a Claude Code session on a branch or PR.

Uninstall: bash scripts/uninstall.sh
EOF
