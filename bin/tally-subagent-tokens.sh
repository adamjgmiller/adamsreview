#!/usr/bin/env bash
# tally-subagent-tokens.sh — roll tokens.jsonl into subagent_tokens on the artifact.
#
# Reads every line of <tokens-log> and writes the aggregate into
# <artifact>.subagent_tokens via artifact-patch.py --set-json. The
# aggregate shape matches schema-v1.json §subagent_tokens:
#
#   { total, invocations, by_phase, by_model, by_lens, by_finding_phase4 }
#
# Safe to call repeatedly — the helper is a pure readback. Phase 6
# of /adamsreview:review invokes it at finalize; the lifecycle commands
# (/adamsreview:fix, /adamsreview:add, /adamsreview:walkthrough)
# invoke it before re-rendering so the PR comment reflects cumulative
# sub-agent spend across the full review → fix/add/walkthrough arc.
#
# tokens: null entries (log-tokens.sh's parse-failure fallback) are
# coerced to 0 in the totals. An empty log produces a zero rollup
# rather than an error.
#
# Usage:
#   tally-subagent-tokens.sh --tokens-log <path> --artifact <path>
#
# Stdout (on success): `tally: total=<N> invocations=<M>`
#
# Exits:
#   0   success
#   1   missing input, write failure, or artifact-patch.py rejection
#   64  usage error

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --tokens-log <path> --artifact <path>

Rolls a tokens.jsonl log into an artifact's subagent_tokens field via
artifact-patch.py --set-json. Emits one summary line to stdout.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

TOKENS_LOG=""
ARTIFACT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tokens-log)
            [[ $# -ge 2 ]] || die_usage "--tokens-log requires a value"
            TOKENS_LOG="${2:-}"; shift 2 ;;
        --artifact)
            [[ $# -ge 2 ]] || die_usage "--artifact requires a value"
            ARTIFACT="${2:-}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$TOKENS_LOG" ]] || die_usage "--tokens-log is required"
[[ -n "$ARTIFACT"   ]] || die_usage "--artifact is required"

if [[ ! -f "$ARTIFACT" ]]; then
    echo "ERROR: artifact not found at $ARTIFACT" >&2
    echo "Action: check the path — the artifact must already exist (Phase 0 inits it)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Missing log → zero rollup, not an error. `jq -s` on /dev/null yields
# [] the same way an empty log does, so we just swap the input path.
# Keeps the helper safe to call unconditionally from any terminus.
if [[ -f "$TOKENS_LOG" ]]; then
    TOKENS_INPUT="$TOKENS_LOG"
else
    TOKENS_INPUT="/dev/null"
fi

# `jq -s` slurps the whole file into a single array. The `// 0` on
# total guards the empty-array case (add on [] is null, which would
# fail schema's integer constraint). group_by branches safely produce
# {} on empty input.
tally_json=$(jq -s '{
  total:       (([.[] | .tokens // 0] | add) // 0),
  invocations: length,
  by_phase:    (group_by(.phase)      | map({key:.[0].phase,      value: (([.[] | .tokens // 0] | add) // 0)}) | from_entries),
  by_model:    (group_by(.model)      | map({key:.[0].model,      value: (([.[] | .tokens // 0] | add) // 0)}) | from_entries),
  by_lens:     ([.[] | select(.agent_role | startswith("lens_"))]
                | group_by(.agent_role) | map({key:.[0].agent_role, value: (([.[] | .tokens // 0] | add) // 0)}) | from_entries),
  by_finding_phase4: ([.[] | select(.phase == "phase_4a" or .phase == "phase_4b")]
                | group_by(.finding_id) | map({key:.[0].finding_id, value: (([.[] | .tokens // 0] | add) // 0)}) | from_entries)
}' "$TOKENS_INPUT")

if [[ -z "$tally_json" ]]; then
    echo "ERROR: tally produced empty output (jq failure?)" >&2
    echo "Action: check $TOKENS_LOG for malformed JSON lines." >&2
    exit 1
fi

tmp="$(mktemp -t tally-subagent-tokens.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

printf '%s\n' "$tally_json" > "$tmp"

"$SCRIPT_DIR/artifact-patch.py" \
    --path "$ARTIFACT" \
    --set-json "subagent_tokens=@$tmp" >/dev/null

total=$(printf '%s' "$tally_json" | jq -r '.total')
invocations=$(printf '%s' "$tally_json" | jq -r '.invocations')
echo "tally: total=${total} invocations=${invocations}"
