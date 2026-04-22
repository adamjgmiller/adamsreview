#!/usr/bin/env bash
# dev-run.sh — launch Claude Code with the working tree loaded as a plugin.
# For plugin-author iteration. For install-path simulation, use
# `/plugin marketplace add .` inside a Claude Code session instead.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec claude --plugin-dir "$REPO_ROOT" "$@"
