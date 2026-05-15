#!/usr/bin/env bash
# trivial-check.sh — Phase 0.11 trivial-diff classification (§13.9).
# Extracts the inline bash block from fragments/00-preflight.md step 0.11.
#
# Classifies a PR diff as "trivial" (doc/config-only, small) or not.
# The orchestrator-side `force_full=true` short-circuit is NOT the
# helper's concern — callers who set `force_full=true` skip this helper
# entirely and set `trivial_mode=false` themselves.
#
# Usage (newline-separated file list on stdin — matches how the
# fragment stores `$reviewed_files_all`):
#   printf '%s\n' $reviewed_files_all \
#     | trivial-check.sh --num-files <N> --lines-changed <N>
#
# Inputs:
#   stdin            newline-separated list of changed file paths
#                    (leading/trailing blank lines ignored).
#   --num-files      Required. Count of files in the diff (step 0.6).
#   --lines-changed  Required. Total added+deleted line count (step 0.6).
#
# Output (stdout): a single JSON object:
#   {"trivial_mode": <bool>, "reason": "docs_only" | null}
#
# Classification (the only trigger implemented — see the plan entry
# for 4.A.2: the "..." future-enum expansion is out of scope):
#
#   trivial_mode = true  AND reason = "docs_only"
#     iff every file on stdin matches the doc/config allow-list
#         AND num_files <= 3
#         AND lines_changed <= 30
#
#   trivial_mode = false AND reason = null
#     otherwise.
#
# Empty-stdin edge case: no files listed → vacuously matches the
# allow-list; if `--num-files 0` and `--lines-changed 0` are also
# supplied, the helper emits `{trivial_mode:true, reason:"docs_only"}`
# — mirrors the pre-extraction fragment (empty `while` loop leaves
# `all_trivial=true`; 0 <= 3 and 0 <= 30 both hold).
#
# Allow-list (matches step 0.11):
#   *.md *.mdx *.txt *.rst *.yaml *.yml *.json *.jsonc *.toml
#   *.ini *.cfg *.conf LICENSE LICENSE.* CHANGELOG* NOTICE*
#   .gitignore .editorconfig .npmrc .nvmrc
#
# Exit codes: 0 success; 1 validation error (e.g., non-integer counts);
# 64 usage error (missing/unknown flag).

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --num-files <N> --lines-changed <N> < <file-list>

Reads a newline-separated list of changed files from stdin and emits a
JSON object \`{trivial_mode, reason}\` classifying the diff per DESIGN
§13.9. The orchestrator handles the \`force_full=true\` short-circuit.

  --num-files       Required. Integer >= 0.
  --lines-changed   Required. Integer >= 0.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

die_validation() {
    echo "ERROR: $1" >&2
    [[ -n "${2:-}" ]] && echo "Action: $2" >&2
    exit 1
}

NUM_FILES=""
LINES_CHANGED=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --num-files)
            [[ $# -ge 2 ]] || die_usage "--num-files requires a value"
            NUM_FILES="${2:-}";     shift 2 ;;
        --lines-changed)
            [[ $# -ge 2 ]] || die_usage "--lines-changed requires a value"
            LINES_CHANGED="${2:-}"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$NUM_FILES" ]]     || die_usage "--num-files is required"
[[ -n "$LINES_CHANGED" ]] || die_usage "--lines-changed is required"

case "$NUM_FILES" in
    ''|*[!0-9]*) die_validation "--num-files must be a non-negative integer, got '$NUM_FILES'" ;;
esac
case "$LINES_CHANGED" in
    ''|*[!0-9]*) die_validation "--lines-changed must be a non-negative integer, got '$LINES_CHANGED'" ;;
esac

# Walk stdin; if any non-blank line fails the allow-list, flip the flag
all_trivial=true
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
        *.md|*.mdx|*.txt|*.rst|*.yaml|*.yml|*.json|*.jsonc|\
        *.toml|*.ini|*.cfg|*.conf|\
        LICENSE|LICENSE.*|CHANGELOG*|NOTICE*|\
        .gitignore|.editorconfig|.npmrc|.nvmrc) ;;
        *) all_trivial=false ;;
    esac
done

if [[ "$all_trivial" == "true" ]] \
    && [[ "$NUM_FILES" -le 3 ]] \
    && [[ "$LINES_CHANGED" -le 30 ]]; then
    jq -n '{trivial_mode: true, reason: "docs_only"}'
else
    jq -n '{trivial_mode: false, reason: null}'
fi
