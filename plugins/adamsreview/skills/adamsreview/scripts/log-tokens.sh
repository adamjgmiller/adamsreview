#!/usr/bin/env bash
# log-tokens.sh — per-sub-agent token usage appender for tokens.jsonl (DESIGN §11).
#
# Usage:
#   log-tokens.sh --review-dir <d> --phase <phase_label> --agent-role <role>
#                 --agent-id <id> --model <name> --tokens <n|null>
#                 [--finding-id <F0XX>] [--lens <L2>]
#
# --tokens accepts an integer OR the literal "null" (DESIGN §11
# parse-failure fallback: if the <usage> block couldn't be extracted
# from a sub-agent's tool result, log "null" and keep the pipeline
# running — token tracking is observability, not correctness).
#
# Emits one JSON line per invocation:
#   {"phase":"phase_4a","agent_role":"validator","finding_id":"F001",
#    "agent_id":"a155...","model":"opus","tokens":27714,
#    "ts":"2026-04-17T19:23:14Z"}
#
# Exits: 0 success; 1 write failure; 64 usage error.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --review-dir <d> --phase <phase_label> --agent-role <role>
                       --agent-id <id> --model <name> --tokens <n|null>
                       [--finding-id <F0XX>] [--lens <L2>]

Appends one JSON line to <review-dir>/tokens.jsonl for post-run
token cost tallies (DESIGN §11). Token value may be "null" when the
<usage> block could not be parsed — that is observability, not an
error.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

REVIEW_DIR=""
PHASE=""
ROLE=""
AGENT_ID=""
MODEL=""
TOKENS=""
FINDING_ID=""
LENS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --review-dir)
            [[ $# -ge 2 ]] || die_usage "--review-dir requires a value"
            REVIEW_DIR="${2:-}"; shift 2 ;;
        --phase)
            [[ $# -ge 2 ]] || die_usage "--phase requires a value"
            PHASE="${2:-}"; shift 2 ;;
        --agent-role)
            [[ $# -ge 2 ]] || die_usage "--agent-role requires a value"
            ROLE="${2:-}"; shift 2 ;;
        --agent-id)
            [[ $# -ge 2 ]] || die_usage "--agent-id requires a value"
            AGENT_ID="${2:-}"; shift 2 ;;
        --model)
            [[ $# -ge 2 ]] || die_usage "--model requires a value"
            MODEL="${2:-}"; shift 2 ;;
        --tokens)
            [[ $# -ge 2 ]] || die_usage "--tokens requires a value"
            TOKENS="${2:-}"; shift 2 ;;
        --finding-id)
            [[ $# -ge 2 ]] || die_usage "--finding-id requires a value"
            FINDING_ID="${2:-}"; shift 2 ;;
        --lens)
            [[ $# -ge 2 ]] || die_usage "--lens requires a value"
            LENS="${2:-}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$REVIEW_DIR" ]] || die_usage "--review-dir is required"
[[ -n "$PHASE" ]]      || die_usage "--phase is required"
[[ -n "$ROLE" ]]       || die_usage "--agent-role is required"
[[ -n "$AGENT_ID" ]]   || die_usage "--agent-id is required"
[[ -n "$MODEL" ]]      || die_usage "--model is required"
[[ -n "$TOKENS" ]]     || die_usage "--tokens is required (integer or literal 'null')"

mkdir -p "$REVIEW_DIR"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build the JSON line via jq so tokens parses as int (or null) and
# all fields escape correctly.
jq -nc \
    --arg phase "$PHASE" \
    --arg role "$ROLE" \
    --arg aid "$AGENT_ID" \
    --arg model "$MODEL" \
    --arg tokens "$TOKENS" \
    --arg fid "$FINDING_ID" \
    --arg lens "$LENS" \
    --arg ts "$TS" \
    '{
        phase: $phase,
        agent_role: $role,
        agent_id: $aid,
        model: $model,
        tokens: ($tokens | if . == "null" then null else tonumber end),
        ts: $ts
    }
    + (if $fid != "" then {finding_id: $fid} else {} end)
    + (if $lens != "" then {lens: $lens} else {} end)' \
    >> "$REVIEW_DIR/tokens.jsonl"
