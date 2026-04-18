#!/usr/bin/env bash
# log-phase.sh — appender for trace.md and phases.jsonl (DESIGN §12, §21.6).
#
# Two modes, selected by the presence of --record:
#
#   Narrative (trace.md):
#     log-phase.sh --review-dir <d> --phase <n> --name <name>
#                  --summary <text> [--elapsed <sec>]
#
#   Structured (phases.jsonl):
#     log-phase.sh --review-dir <d> --phase <n> --record '<json>'
#
# --record's value is a JSON object; the script adds a `ts` field (ISO
# UTC) and a `phase` field if not already present, then appends one
# line. Pre-formatted JSON is passed through `jq -c` for shape check
# so a malformed record doesn't silently corrupt phases.jsonl.
#
# Exits: 0 success; 1 write failure or malformed --record JSON;
# 64 usage error.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage:
  $(basename "$0") --review-dir <d> --phase <n> --name <name> --summary <text> [--elapsed <sec>]
  $(basename "$0") --review-dir <d> --phase <n> --record '<json>'

Modes:
  narrative (trace.md):   --summary + --name
  structured (jsonl):     --record
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

REVIEW_DIR=""
PHASE=""
NAME=""
SUMMARY=""
ELAPSED=""
RECORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --review-dir) REVIEW_DIR="${2:-}"; shift 2 ;;
        --phase)      PHASE="${2:-}"; shift 2 ;;
        --name)       NAME="${2:-}"; shift 2 ;;
        --summary)    SUMMARY="${2:-}"; shift 2 ;;
        --elapsed)    ELAPSED="${2:-}"; shift 2 ;;
        --record)     RECORD="${2:-}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$REVIEW_DIR" ]] || die_usage "--review-dir is required"
[[ -n "$PHASE" ]]      || die_usage "--phase is required"

if [[ ! -d "$REVIEW_DIR" ]]; then
    mkdir -p "$REVIEW_DIR"
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ -n "$RECORD" ]]; then
    [[ -z "$NAME" && -z "$SUMMARY" && -z "$ELAPSED" ]] \
        || die_usage "--record cannot combine with --name / --summary / --elapsed"

    # Validate JSON object and inject phase + ts if absent. --phase may be
    # numeric ("3") or a string bucket key ("1_5", "phase_4a" — see §11
    # conventions). tonumber? with string fallback handles both.
    if ! enriched=$(printf '%s' "$RECORD" \
        | jq -c --arg phase "$PHASE" --arg ts "$TS" \
            '(if type != "object" then error("record must be a JSON object") else . end) | (.phase //= ($phase|tonumber? // $phase)) | (.ts //= $ts)' \
        2>&1); then
        echo "ERROR: --record is not a valid JSON object: $enriched" >&2
        echo "Action: pass a JSON object like '{\"name\":\"detection\",\"elapsed_sec\":45,...}'." >&2
        exit 1
    fi

    echo "$enriched" >> "$REVIEW_DIR/phases.jsonl"
    exit 0
fi

[[ -n "$NAME" ]]    || die_usage "--name is required (narrative mode)"
[[ -n "$SUMMARY" ]] || die_usage "--summary is required (narrative mode)"

{
    if [[ -n "$ELAPSED" ]]; then
        echo "## Phase $PHASE — $NAME (elapsed: ${ELAPSED}s)"
    else
        echo "## Phase $PHASE — $NAME"
    fi
    echo "$SUMMARY"
    echo ""
} >> "$REVIEW_DIR/trace.md"
