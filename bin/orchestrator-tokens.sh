#!/usr/bin/env bash
# orchestrator-tokens.sh — roll Claude Code session-transcript usage
# into `orchestrator_tokens` on the artifact.
#
# Background: `subagent_tokens` (via tally-subagent-tokens.sh) captures
# every dispatched sub-agent's spend but deliberately excludes the main
# orchestrator session (DESIGN §11). This helper closes that gap by
# reading every .jsonl transcript under `~/.claude/projects/<cwd-slug>/`
# whose assistant-line timestamps fall within the review window, summing
# the four `message.usage` counters (fresh input, output, cache-read,
# cache-creation), and writing the rollup into `<artifact>.orchestrator_tokens`
# via artifact-patch.py --set-json.
#
# Four counters are preserved separately — cache-read $/token is roughly
# an order of magnitude cheaper than fresh input, so collapsing them
# hides the real cost signal.
#
# Scope filter is a pure time-window: assistant lines with
# timestamp >= $since (the review's review_started_at). The filter has
# two known over-count modes, documented as acceptable for v1:
#   1. Unrelated Claude Code sessions running in the same cwd during
#      the review lifecycle (captured by the directory scan).
#   2. Review-session turns on unrelated chat between lifecycle commands
#      (captured by the time-window filter).
# Both bias towards over-count, never under-count.
#
# Transcript discovery:
#   - Default: list every *.jsonl under $PROJECTS_ROOT/<slug>/ where
#     <slug> = `$(pwd -P | tr '/.' '-')`. Both `/` AND `.` map to `-`
#     (this is Claude Code's own convention — e.g. `/.claude/` becomes
#     `--claude-`, not `-.claude-`).
#   - --transcript-dir overrides the slug derivation. Used by smoke
#     so tests don't accidentally read real user transcripts.
#
# Safe to call repeatedly. Missing transcript dir, zero matching
# transcripts, or a transcript with all pre-since turns → zero rollup
# with sessions=[] rather than an error.
#
# Opt-in: defaults to skip unless `ADAMS_REVIEW_TALLY_ORCHESTRATOR=1`
# (or true/yes/on) is set in the environment. The transcript scan
# triggers the macOS "access data from other apps" prompt because
# Claude Code marks every transcript with the `com.apple.provenance`
# xattr; users are spared the prompt by default. When opted out the
# helper exits 0 with one stdout line and does not touch the artifact —
# any previously-written orchestrator_tokens stays put.
#
# Usage:
#   orchestrator-tokens.sh --artifact <path> --since <iso-ts> \
#       [--projects-root <path>] [--cwd <path>] [--transcript-dir <path>]
#
# Stdout (on success):
#   `orchestrator-tally: total_input=<N> output=<N> cache_read=<N> cache_creation=<N> turns=<N> sessions=<M>`
#
# Exits:
#   0   success
#   1   missing artifact, write failure, or artifact-patch.py rejection
#   64  usage error

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --artifact <path> --since <iso-ts> [--projects-root <path>] [--cwd <path>] [--transcript-dir <path>]

Rolls Claude Code session transcripts into an artifact's orchestrator_tokens
field via artifact-patch.py --set-json. Emits one summary line to stdout.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

ARTIFACT=""
SINCE=""
PROJECTS_ROOT="${HOME}/.claude/projects"
CWD="$(pwd -P)"
TRANSCRIPT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifact)
            [[ $# -ge 2 ]] || die_usage "--artifact requires a value"
            ARTIFACT="${2:-}"; shift 2 ;;
        --since)
            [[ $# -ge 2 ]] || die_usage "--since requires a value"
            SINCE="${2:-}"; shift 2 ;;
        --projects-root)
            [[ $# -ge 2 ]] || die_usage "--projects-root requires a value"
            PROJECTS_ROOT="${2:-}"; shift 2 ;;
        --cwd)
            [[ $# -ge 2 ]] || die_usage "--cwd requires a value"
            CWD="${2:-}"; shift 2 ;;
        --transcript-dir)
            [[ $# -ge 2 ]] || die_usage "--transcript-dir requires a value"
            TRANSCRIPT_DIR="${2:-}"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *)                 die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$ARTIFACT" ]] || die_usage "--artifact is required"
[[ -n "$SINCE" ]]    || die_usage "--since is required"

# Opt-in gate. macOS Sequoia/Tahoe prompts the controlling terminal app
# for "access data from other apps" when reading files carrying the
# `com.apple.provenance` xattr — every Claude Code transcript under
# `~/.claude/projects/` carries one. The `find ... -name '*.jsonl'`
# scan below is the trigger. Granting the terminal Full Disk Access
# silences the prompt class permanently; until then, default to skip
# so users aren't pestered. Opting in is one env var in your shell rc.
# Skip preserves any previously-written orchestrator_tokens on the
# artifact (a prior opted-in run still surfaces in the rendered line).
opt_in="${ADAMS_REVIEW_TALLY_ORCHESTRATOR:-}"
case "$opt_in" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *)
        echo "orchestrator-tally: skipped (set ADAMS_REVIEW_TALLY_ORCHESTRATOR=1 to enable; see README §Token counts)"
        exit 0
        ;;
esac

if [[ ! -f "$ARTIFACT" ]]; then
    echo "ERROR: artifact not found at $ARTIFACT" >&2
    echo "Action: check the path — the artifact must already exist (Phase 0 inits it)." >&2
    exit 1
fi

# Normalize $SINCE: Phase 0 writes review_started_at at second
# precision via `date -u +%Y-%m-%dT%H:%M:%SZ`, but Claude Code
# transcript timestamps carry milliseconds (e.g.
# 2026-04-21T23:37:36.102Z). The lexical `>=` comparison used below
# treats `.` (0x2E) as less than `Z` (0x5A), so without normalization
# a turn at `...:36.500Z` compares LESS than `--since "...:36Z"` and
# would be silently excluded. Pad the bare-seconds form to `.000Z`
# so same-second turns are included as expected.
# Narrow regex: only normalizes the exact shape Phase 0 writes.
# Any fractional-seconds input passes through unchanged.
if [[ "$SINCE" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})Z$ ]]; then
    SINCE="${BASH_REMATCH[1]}.000Z"
fi

# Slug derivation only runs when --transcript-dir is not explicitly
# provided. Using tr to map both `/` and `.` matches Claude Code's own
# path-to-directory convention; writing the algorithm inline keeps the
# helper self-contained (no sibling slug helper yet).
if [[ -z "$TRANSCRIPT_DIR" ]]; then
    slug=$(printf '%s' "$CWD" | tr '/.' '-')
    TRANSCRIPT_DIR="$PROJECTS_ROOT/$slug"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Collect transcripts. Missing dir or zero matches → zero rollup.
# `sort` makes the sessions[] ordering deterministic for testing; jq's
# later sort_by(.first_seen) is the user-facing order.
transcripts=()
if [[ -d "$TRANSCRIPT_DIR" ]]; then
    while IFS= read -r f; do
        [[ -n "$f" ]] && transcripts+=("$f")
    done < <(find "$TRANSCRIPT_DIR" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null | sort)
fi

# Combined stream: each JSONL line is annotated with its source path
# before jq slurps everything. Per-file jq errors are swallowed with
# `|| true` so a truncated or malformed transcript yields partial data
# rather than aborting the whole tally. Worst case we miss a handful
# of turns from a broken file; we still count everything valid.
combined_stream() {
    local t
    for t in "${transcripts[@]}"; do
        jq -c --arg path "$t" '. + {_transcript_path: $path}' "$t" 2>/dev/null || true
    done
}

# Zero-transcript path uses `jq -n` to synthesize the empty rollup
# directly. This is the single source of truth for the zero shape,
# so the schema's required fields always get populated.
if [[ ${#transcripts[@]} -eq 0 ]]; then
    tally_json=$(jq -n '{
        total_input: 0,
        total_output: 0,
        cache_read: 0,
        cache_creation: 0,
        turn_count: 0,
        sessions: []
    }')
else
    # Populated-transcripts path. Filter assistant turns with
    # timestamp >= since (string comparison is safe for ISO-8601).
    # The `// 0` guards keep totals valid on empty post-filter arrays,
    # matching tally-subagent-tokens.sh's defensive style.
    tally_json=$(combined_stream | jq -cs --arg since "$SINCE" '
        [ .[] | select(.type == "assistant" and ((.timestamp // "") >= $since)) ] as $turns
        | {
            total_input:    (([ $turns[] | .message.usage.input_tokens                // 0 ] | add) // 0),
            total_output:   (([ $turns[] | .message.usage.output_tokens               // 0 ] | add) // 0),
            cache_read:     (([ $turns[] | .message.usage.cache_read_input_tokens     // 0 ] | add) // 0),
            cache_creation: (([ $turns[] | .message.usage.cache_creation_input_tokens // 0 ] | add) // 0),
            turn_count:     ($turns | length),
            sessions: (
                $turns
                | group_by(.sessionId)
                | map({
                    session_id:      (.[0].sessionId // ""),
                    transcript_path: (.[0]._transcript_path // ""),
                    first_seen:      ([ .[] | .timestamp // "" ] | min),
                    last_seen:       ([ .[] | .timestamp // "" ] | max),
                    turn_count:      length
                  })
                | sort_by(.first_seen)
            )
          }
    ')
fi

if [[ -z "$tally_json" ]]; then
    echo "ERROR: orchestrator tally produced empty output (jq failure?)" >&2
    echo "Action: inspect transcripts under $TRANSCRIPT_DIR for malformed JSON lines." >&2
    exit 1
fi

tmp="$(mktemp -t orchestrator-tokens.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

printf '%s\n' "$tally_json" > "$tmp"

"$SCRIPT_DIR/artifact-patch.py" \
    --path "$ARTIFACT" \
    --set-json "orchestrator_tokens=@$tmp" >/dev/null

total_input=$(printf '%s'    "$tally_json" | jq -r '.total_input')
total_output=$(printf '%s'   "$tally_json" | jq -r '.total_output')
cache_read=$(printf '%s'     "$tally_json" | jq -r '.cache_read')
cache_creation=$(printf '%s' "$tally_json" | jq -r '.cache_creation')
turns=$(printf '%s'          "$tally_json" | jq -r '.turn_count')
sessions=$(printf '%s'       "$tally_json" | jq -r '.sessions | length')

echo "orchestrator-tally: total_input=${total_input} output=${total_output} cache_read=${cache_read} cache_creation=${cache_creation} turns=${turns} sessions=${sessions}"
