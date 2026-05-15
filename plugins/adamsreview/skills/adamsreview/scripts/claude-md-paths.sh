#!/usr/bin/env bash
# Compatibility wrapper for schema-v1 and older tests. The Codex-native
# scanner is instruction-paths.sh and returns AGENTS.md plus legacy project instruction files.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$script_dir/instruction-paths.sh" "$@"
