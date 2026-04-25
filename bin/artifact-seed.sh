#!/usr/bin/env bash
# artifact-seed.sh — Phase 0.15 initial-artifact seed construction.
# Extracts the main 48-line `jq -n` block from fragments/00-preflight.md
# step 0.15. Pure output helper: emits schema-shaped seed JSON on stdout
# for `artifact-patch.py --init -` to consume. Makes no on-disk
# mutations — the downstream `--init` call is what writes the artifact.
#
# The `base_context` sub-object (§13.10 freshness reconciliation) is
# still built by the fragment via `jq -n` and passed as a single JSON
# string through `--base-context`. Keeping the sub-object construction
# in the fragment preserves its explicit null-handling for the offline /
# no-remote paths and keeps the helper's arg surface uniform (every
# nullable field arrives as a flag value, not smuggled through string
# concatenation).
#
# Usage:
#   artifact-seed.sh \
#       --review-id "$review_id" \
#       --review-started-at "$review_started_at" \
#       --reviewed-sha "$reviewed_sha" \
#       --base-branch "$base_branch" \
#       --head-branch "$head_branch" \
#       --mode "$mode" \
#       --pr-state "${pr_state:-}" \
#       --pr-number "${pr_number:-}" \
#       --comment-id "${existing_comment_id:-}" \
#       --trivial-mode "$trivial_mode" \
#       --base-context "$base_context_json" \
#       --reviewed-files-all "$reviewed_files_all" \
#       --claude-md-paths "$claude_md_paths" \
#       --files-changed "$num_files" \
#       --lines-changed "$lines_changed" \
#     | artifact-patch.py --init - --path "$artifact_path"
#
# Flag shapes (all required; empty-string semantics called out):
#   --review-id          String matching ^rev_[A-Za-z0-9]+$.
#   --review-started-at  ISO-8601 UTC timestamp. Seeds `generated_at`
#                        and `review_started_at` to the same value.
#   --reviewed-sha       7-40 hex chars.
#   --base-branch        Non-empty string.
#   --head-branch        Non-empty string.
#   --mode               `pr` | `local`.
#   --pr-state           `draft` | `open` | "" (empty → JSON null).
#   --pr-number          Positive integer | "" (empty → JSON null).
#   --comment-id         Positive integer | "" (empty → JSON null).
#   --trivial-mode       `true` | `false` (Bash-string boolean).
#   --base-context       A JSON object string conforming to the
#                        schema's $defs/base_context (freshness,
#                        comparison_ref, nullable remote_sha,
#                        nullable behind_count). Validated by jq parse.
#   --reviewed-files-all Newline-separated file list. Empty lines are
#                        dropped; output is a JSON string array.
#   --claude-md-paths    Newline-separated path list. Empty lines are
#                        dropped; output is a JSON string array.
#   --files-changed      Non-negative integer.
#   --lines-changed      Non-negative integer.
#
# Output (stdout): the schema-shaped seed JSON for the new artifact.
# `artifact-patch.py --init -` validates it against `bin/schema-v1.json`
# and either writes the artifact or exits non-zero with error-as-prompt
# stderr (handled by the fragment's retry-once-and-escalate path).
#
# Exit codes: 0 success; 1 validation error (bad flag value, malformed
# --base-context JSON); 64 usage error (missing/unknown flag).

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") \\
    --review-id <rev_...> --review-started-at <iso8601> \\
    --reviewed-sha <sha> --base-branch <name> --head-branch <name> \\
    --mode <pr|local> --pr-state <draft|open|""> \\
    --pr-number <int|""> --comment-id <int|""> \\
    --trivial-mode <true|false> --base-context <json> \\
    --reviewed-files-all <newline-sep> --claude-md-paths <newline-sep> \\
    --files-changed <int> --lines-changed <int>

Emits the schema-shaped seed JSON for a fresh review artifact. Pipe into
\`artifact-patch.py --init -\` to persist it. All flags are required;
nullable fields (\`pr-state\`, \`pr-number\`, \`comment-id\`) accept the
empty string to emit JSON null.

See fragments/00-preflight.md step 0.15 for the orchestrator-side call
site and the retry-once-and-escalate error path.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

die_validation() {
    echo "ERROR: $1" >&2
    [[ -n "${2:-}" ]] && echo "Action: $2" >&2
    exit 1
}

REVIEW_ID=""
REVIEW_STARTED_AT=""
REVIEWED_SHA=""
BASE_BRANCH=""
HEAD_BRANCH=""
MODE=""
PR_STATE=""
PR_NUMBER=""
COMMENT_ID=""
TRIVIAL_MODE=""
BASE_CONTEXT=""
REVIEWED_FILES_ALL=""
CLAUDE_MD_PATHS=""
FILES_CHANGED=""
LINES_CHANGED=""

# Track presence separately from value — every flag but the newline-sep
# lists and the three nullable ones must be non-empty, and we want to
# distinguish "flag not supplied" from "flag supplied with empty value"
# for those three.
have_pr_state=0
have_pr_number=0
have_comment_id=0
have_reviewed_files_all=0
have_claude_md_paths=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --review-id)
            [[ $# -ge 2 ]] || die_usage "--review-id requires a value"
            REVIEW_ID="${2:-}";           shift 2 ;;
        --review-started-at)
            [[ $# -ge 2 ]] || die_usage "--review-started-at requires a value"
            REVIEW_STARTED_AT="${2:-}";   shift 2 ;;
        --reviewed-sha)
            [[ $# -ge 2 ]] || die_usage "--reviewed-sha requires a value"
            REVIEWED_SHA="${2:-}";        shift 2 ;;
        --base-branch)
            [[ $# -ge 2 ]] || die_usage "--base-branch requires a value"
            BASE_BRANCH="${2:-}";         shift 2 ;;
        --head-branch)
            [[ $# -ge 2 ]] || die_usage "--head-branch requires a value"
            HEAD_BRANCH="${2:-}";         shift 2 ;;
        --mode)
            [[ $# -ge 2 ]] || die_usage "--mode requires a value"
            MODE="${2:-}";                shift 2 ;;
        --pr-state)
            [[ $# -ge 2 ]] || die_usage "--pr-state requires a value"
            PR_STATE="${2:-}";            have_pr_state=1;            shift 2 ;;
        --pr-number)
            [[ $# -ge 2 ]] || die_usage "--pr-number requires a value"
            PR_NUMBER="${2:-}";           have_pr_number=1;           shift 2 ;;
        --comment-id)
            [[ $# -ge 2 ]] || die_usage "--comment-id requires a value"
            COMMENT_ID="${2:-}";          have_comment_id=1;          shift 2 ;;
        --trivial-mode)
            [[ $# -ge 2 ]] || die_usage "--trivial-mode requires a value"
            TRIVIAL_MODE="${2:-}";        shift 2 ;;
        --base-context)
            [[ $# -ge 2 ]] || die_usage "--base-context requires a value"
            BASE_CONTEXT="${2:-}";        shift 2 ;;
        --reviewed-files-all)
            [[ $# -ge 2 ]] || die_usage "--reviewed-files-all requires a value"
            REVIEWED_FILES_ALL="${2:-}";  have_reviewed_files_all=1;  shift 2 ;;
        --claude-md-paths)
            [[ $# -ge 2 ]] || die_usage "--claude-md-paths requires a value"
            CLAUDE_MD_PATHS="${2:-}";     have_claude_md_paths=1;     shift 2 ;;
        --files-changed)
            [[ $# -ge 2 ]] || die_usage "--files-changed requires a value"
            FILES_CHANGED="${2:-}";       shift 2 ;;
        --lines-changed)
            [[ $# -ge 2 ]] || die_usage "--lines-changed requires a value"
            LINES_CHANGED="${2:-}";       shift 2 ;;
        -h|--help)             usage; exit 0 ;;
        *)                     die_usage "unknown arg '$1'" ;;
    esac
done

# --- required-flag validation -------------------------------------------

[[ -n "$REVIEW_ID" ]]         || die_usage "--review-id is required"
[[ -n "$REVIEW_STARTED_AT" ]] || die_usage "--review-started-at is required"
[[ -n "$REVIEWED_SHA" ]]      || die_usage "--reviewed-sha is required"
[[ -n "$BASE_BRANCH" ]]       || die_usage "--base-branch is required"
[[ -n "$HEAD_BRANCH" ]]       || die_usage "--head-branch is required"
[[ -n "$MODE" ]]              || die_usage "--mode is required"
[[ -n "$TRIVIAL_MODE" ]]      || die_usage "--trivial-mode is required"
[[ -n "$BASE_CONTEXT" ]]      || die_usage "--base-context is required"
[[ -n "$FILES_CHANGED" ]]     || die_usage "--files-changed is required"
[[ -n "$LINES_CHANGED" ]]     || die_usage "--lines-changed is required"
[[ "$have_pr_state" -eq 1 ]]           || die_usage "--pr-state is required"
[[ "$have_pr_number" -eq 1 ]]          || die_usage "--pr-number is required"
[[ "$have_comment_id" -eq 1 ]]         || die_usage "--comment-id is required"
[[ "$have_reviewed_files_all" -eq 1 ]] || die_usage "--reviewed-files-all is required"
[[ "$have_claude_md_paths" -eq 1 ]]    || die_usage "--claude-md-paths is required"

# --- value validation ----------------------------------------------------

# review_id shape matches the schema pattern exactly — catch typos here
# rather than force the caller to read the `--init` error-as-prompt.
case "$REVIEW_ID" in
    rev_*) ;;
    *) die_validation "--review-id must match ^rev_[A-Za-z0-9]+\$, got '$REVIEW_ID'" ;;
esac

case "$MODE" in
    pr|local) ;;
    *) die_validation "--mode must be 'pr' or 'local', got '$MODE'" ;;
esac

case "$PR_STATE" in
    ""|draft|open) ;;
    *) die_validation "--pr-state must be '', 'draft', or 'open', got '$PR_STATE'" ;;
esac

case "$TRIVIAL_MODE" in
    true|false) ;;
    *) die_validation "--trivial-mode must be 'true' or 'false', got '$TRIVIAL_MODE'" ;;
esac

# pr-number / comment-id / files-changed / lines-changed are integers;
# the first two are nullable (empty string → null).
case "$PR_NUMBER" in
    ''|*[!0-9]*)
        [[ -z "$PR_NUMBER" ]] || die_validation "--pr-number must be a positive integer or empty, got '$PR_NUMBER'" ;;
esac
case "$COMMENT_ID" in
    ''|*[!0-9]*)
        [[ -z "$COMMENT_ID" ]] || die_validation "--comment-id must be a positive integer or empty, got '$COMMENT_ID'" ;;
esac
case "$FILES_CHANGED" in
    ''|*[!0-9]*) die_validation "--files-changed must be a non-negative integer, got '$FILES_CHANGED'" ;;
esac
case "$LINES_CHANGED" in
    ''|*[!0-9]*) die_validation "--lines-changed must be a non-negative integer, got '$LINES_CHANGED'" ;;
esac

# --base-context must parse as JSON. We don't enforce the sub-schema
# here — `artifact-patch.py --init` validates the whole seed against
# schema-v1.json, and a malformed sub-object surfaces there with a
# clearer jsonschema error path.
if ! printf '%s' "$BASE_CONTEXT" | jq -e . >/dev/null 2>&1; then
    die_validation "--base-context must be a JSON object, got '$BASE_CONTEXT'" \
        "build the sub-object via \`jq -n\` before invoking this helper."
fi

# --- JSON-array construction for the newline-sep flags -------------------

reviewed_files_all_json=$(printf '%s' "$REVIEWED_FILES_ALL" | jq -Rn '[inputs | select(length>0)]')
claude_md_paths_json=$(printf '%s' "$CLAUDE_MD_PATHS" | jq -Rn '[inputs | select(length>0)]')

# --- main seed -----------------------------------------------------------

# `generated_at` seeds to `review_started_at` — Phase 6 finalize re-sets
# `generated_at` to the completion timestamp, but the seed must satisfy
# schema-v1.json's `required` list, so both fields ship on day one.
# `pr_number` / `comment_id` use `--arg` + tonumber-on-non-empty rather
# than `--argjson` because the nullable-integer path needs a shell-side
# empty-string check; mirrors `freshness-gate.sh`'s behind_count pattern.
jq -n \
    --arg review_id "$REVIEW_ID" \
    --arg generated_at "$REVIEW_STARTED_AT" \
    --arg review_started_at "$REVIEW_STARTED_AT" \
    --arg reviewed_sha "$REVIEWED_SHA" \
    --arg base_branch "$BASE_BRANCH" \
    --arg head_branch "$HEAD_BRANCH" \
    --arg mode "$MODE" \
    --arg pr_state "$PR_STATE" \
    --arg pr_number "$PR_NUMBER" \
    --arg comment_id "$COMMENT_ID" \
    --argjson trivial_mode "$TRIVIAL_MODE" \
    --argjson base_context "$BASE_CONTEXT" \
    --argjson reviewed_files_all "$reviewed_files_all_json" \
    --argjson claude_md_paths "$claude_md_paths_json" \
    --argjson files_changed "$FILES_CHANGED" \
    --argjson lines_changed "$LINES_CHANGED" \
    '{
        schema_version: 1,
        review_id: $review_id,
        generated_at: $generated_at,
        review_started_at: $review_started_at,
        reviewed_sha: $reviewed_sha,
        base_branch: $base_branch,
        head_branch: $head_branch,
        mode: $mode,
        pr_state: (if $pr_state == "" then null else $pr_state end),
        pr_number: (if $pr_number == "" then null else ($pr_number | tonumber) end),
        comment_id: (if $comment_id == "" then null else ($comment_id | tonumber) end),
        trivial_mode: $trivial_mode,
        base_context: $base_context,
        reviewer_sources: ["internal"],
        reviewed_files_all: $reviewed_files_all,
        claude_md_paths: $claude_md_paths,
        findings: [],
        cross_cutting_groups: [],
        subagent_tokens: {
            total: 0, invocations: 0, by_phase: {}, by_model: {},
            by_lens: {}, by_finding_phase4: {}
        },
        metrics: {
            phase_9_verified_pct: null,
            required_followup: null,
            time_elapsed_seconds: null,
            pr_size_buckets: {files_changed: $files_changed, lines_changed: $lines_changed}
        }
    }'
