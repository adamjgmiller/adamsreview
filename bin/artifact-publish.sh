#!/usr/bin/env bash
# artifact-publish.sh — rendered-report publisher (DESIGN §21.6, §13.4, §8.4).
#
# PR mode: post or edit the rendered `artifact.md` on a GitHub PR.
# Local mode: no-op. (Local-mode exists so the orchestrator can call
# this unconditionally in every mode.)
#
# Usage:
#   artifact-publish.sh --mode pr --review-id <id> --pr <num> \
#                       (--md-path <path> | --repo-slug <slug> --branch <name>) \
#                       [--comment-id <n>] [--review-dir <path>] [--dry-run]
#   artifact-publish.sh --mode local --review-id <id> [--review-dir <path>]
#
# md-path resolution (first match wins):
#   1. --md-path <path>        (explicit override; used by Stage 1 smoke harness)
#   2. --review-dir <path>     (review dir set by caller; reads <dir>/artifact.md)
#   3. --repo-slug + --branch  (latest.txt fallback — DESIGN §13.4):
#        <reviews-root>/<slug>/<branch>/latest.txt → <review_id> →
#        <reviews-root>/<slug>/<branch>/<review_id>/artifact.md
#      where <reviews-root> is $ADAMS_REVIEW_REVIEWS_ROOT (default
#      ~/.adams-reviews). If the resolved review_id disagrees with
#      --review-id, exit 1 with a staleness note.
#
# Comment discovery (§13.4, in order):
#   1. --comment-id passed → PATCH. On PATCH failure (comment deleted
#      out-of-band) → POST, emit new {"comment_id": N}, log fallback.
#   2. No --comment-id → POST new comment → emit {"comment_id": N}.
#
# The helper never auto-discovers a prior comment via marker search.
# Continuation intent is the caller's responsibility: fresh /adamsreview:review
# calls without --comment-id (→ new comment); /adamsreview:fix and
# /adamsreview:promote carry the prior comment_id forward from the
# artifact and pass it explicitly (→ edit in place). See DESIGN §13.4.
#
# --dry-run: exits 0 after arg validation + md-path resolution; prints the
# resolved md path to stdout. No gh api calls. Useful for smoke tests and
# orchestrator-side debugging.
#
# Exits: 0 success; 1 gh/network/resolution error; 64 usage.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage:
  $(basename "$0") --mode pr    --review-id <id> --pr <num> \\
                                (--md-path <path> | --repo-slug <slug> --branch <name>) \\
                                [--comment-id <n>] [--review-dir <path>] [--dry-run]
  $(basename "$0") --mode local --review-id <id> [--review-dir <path>]

Modes:
  pr     Post or edit the rendered artifact.md on a GitHub PR via gh.
         Requires --pr plus one of --md-path, --review-dir, or
         (--repo-slug AND --branch). Comment discovery:
           --comment-id → PATCH (with POST fallback on failure).
           no --comment-id → POST a new comment.
         Emits {"comment_id": N} to stdout on POST.
  local  No-op. If --review-dir is given, appends a one-line entry to
         <review-dir>/trace.md so the orchestrator's trace reflects
         that publish ran.

Flags:
  --dry-run  Validate args + resolve md path, print resolved path, exit 0.
             No gh api calls.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

MODE=""
REVIEW_ID=""
PR_NUM=""
MD_PATH=""
COMMENT_ID=""
REVIEW_DIR=""
REPO_SLUG=""
BRANCH=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            [[ $# -ge 2 ]] || die_usage "--mode requires a value"
            MODE="${2:-}"; shift 2 ;;
        --review-id)
            [[ $# -ge 2 ]] || die_usage "--review-id requires a value"
            REVIEW_ID="${2:-}"; shift 2 ;;
        --pr)
            [[ $# -ge 2 ]] || die_usage "--pr requires a value"
            PR_NUM="${2:-}"; shift 2 ;;
        --md-path)
            [[ $# -ge 2 ]] || die_usage "--md-path requires a value"
            MD_PATH="${2:-}"; shift 2 ;;
        --comment-id)
            [[ $# -ge 2 ]] || die_usage "--comment-id requires a value"
            COMMENT_ID="${2:-}"; shift 2 ;;
        --review-dir)
            [[ $# -ge 2 ]] || die_usage "--review-dir requires a value"
            REVIEW_DIR="${2:-}"; shift 2 ;;
        --repo-slug)
            [[ $# -ge 2 ]] || die_usage "--repo-slug requires a value"
            REPO_SLUG="${2:-}"; shift 2 ;;
        --branch)
            [[ $# -ge 2 ]] || die_usage "--branch requires a value"
            BRANCH="${2:-}"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$MODE" ]]      || die_usage "--mode is required (pr|local)"
[[ -n "$REVIEW_ID" ]] || die_usage "--review-id is required"

case "$MODE" in
    pr|local) : ;;
    *) die_usage "invalid --mode '$MODE' (valid: pr, local)" ;;
esac

# ------------------------------------------------------------------ helpers

trace_append() {
    # $1 = line to append
    [[ -n "$REVIEW_DIR" ]] || return 0
    mkdir -p "$REVIEW_DIR"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
        echo "## publish ($ts)"
        echo "$1"
        echo ""
    } >> "$REVIEW_DIR/trace.md"
}

emit_comment_id() {
    # $1 = numeric comment id. Emits a one-line JSON object to stdout
    # (DESIGN §21.6: "emit the comment id to stdout as {\"comment_id\": <n>}").
    printf '{"comment_id": %s}\n' "$1"
}

# resolve_md_path — populates MD_PATH via the 3-tier fallback described in
# the header. Exits 1 with error-as-prompt if none of the tiers resolves.
resolve_md_path() {
    # Tier 1: explicit override (Stage 1 smoke compat).
    if [[ -n "$MD_PATH" ]]; then
        return 0
    fi

    # Tier 2: --review-dir/artifact.md (caller knows the review dir).
    if [[ -n "$REVIEW_DIR" ]]; then
        MD_PATH="$REVIEW_DIR/artifact.md"
        return 0
    fi

    # Tier 3: latest.txt under <reviews-root>/<slug>/<branch>/.
    if [[ -n "$REPO_SLUG" && -n "$BRANCH" ]]; then
        local reviews_root_base="${ADAMS_REVIEW_REVIEWS_ROOT:-$HOME/.adams-reviews}"
        local reviews_root="$reviews_root_base/$REPO_SLUG/$BRANCH"
        local latest_file="$reviews_root/latest.txt"
        if [[ ! -f "$latest_file" ]]; then
            echo "ERROR: latest.txt not found at $latest_file" >&2
            echo "Context: expected for --repo-slug=$REPO_SLUG --branch=$BRANCH" >&2
            echo "Action: run /adamsreview:review against this branch first, or pass --md-path explicitly." >&2
            exit 1
        fi
        local resolved_id
        resolved_id=$(tr -d '[:space:]' < "$latest_file")
        if [[ -z "$resolved_id" ]]; then
            echo "ERROR: latest.txt at $latest_file is empty" >&2
            echo "Action: rerun /adamsreview:review to repopulate, or pass --md-path explicitly." >&2
            exit 1
        fi
        if [[ "$resolved_id" != "$REVIEW_ID" ]]; then
            echo "ERROR: latest.txt points to review_id='$resolved_id' but caller passed --review-id='$REVIEW_ID'" >&2
            echo "Context: the 'latest' pointer has moved since the caller captured it (concurrent run, or stale context)." >&2
            echo "Action: use the resolved id explicitly via --md-path=$reviews_root/$resolved_id/artifact.md, or re-capture review_id from latest.txt." >&2
            exit 1
        fi
        MD_PATH="$reviews_root/$resolved_id/artifact.md"
        return 0
    fi

    echo "ERROR: cannot resolve md path" >&2
    echo "Valid sources (one required for --mode=pr): --md-path, --review-dir, or (--repo-slug AND --branch)." >&2
    echo "Action: pass one of those args." >&2
    exit 1
}

require_pr_args() {
    [[ -n "$PR_NUM" ]] || die_usage "--pr is required when --mode=pr"
    resolve_md_path
    [[ -f "$MD_PATH" ]] || {
        echo "ERROR: resolved md path not found: $MD_PATH" >&2
        echo "Action: run artifact-render.py first to produce artifact.md." >&2
        exit 1
    }
}

gh_owner_repo() {
    # Returns "owner/name" via gh. Errors bubble up.
    gh repo view --json nameWithOwner -q .nameWithOwner
}

# gh api with method + JSON body via stdin. $1=method, $2=path, $3=body-file.
gh_send_body() {
    local method="$1" path="$2" body_file="$3"
    gh api -X "$method" "$path" \
        -H "Accept: application/vnd.github+json" \
        --input "$body_file"
}

# ------------------------------------------------------------------ local mode

if [[ "$MODE" == "local" ]]; then
    trace_append "local mode, nothing to publish"
    exit 0
fi

# ------------------------------------------------------------------ pr mode

require_pr_args

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "$MD_PATH"
    exit 0
fi

OWNER_REPO=$(gh_owner_repo) || {
    echo "ERROR: could not resolve owner/repo via 'gh repo view'" >&2
    echo "Action: run 'gh auth login' and 'gh repo view' in this directory to verify." >&2
    exit 1
}

# Build the JSON body once (GitHub comment PATCH/POST both take {"body": "..."}).
BODY_JSON=$(mktemp -t publish-body.XXXXXX)
trap 'rm -f "$BODY_JSON"' EXIT
jq -Rs '{body: .}' "$MD_PATH" > "$BODY_JSON"

patch_comment() {
    # $1 = comment id. Returns 0 on success.
    gh_send_body PATCH "repos/$OWNER_REPO/issues/comments/$1" "$BODY_JSON" > /dev/null
}

post_comment() {
    # Emits the new comment id to stdout on success.
    local new_id
    new_id=$(gh_send_body POST "repos/$OWNER_REPO/issues/$PR_NUM/comments" "$BODY_JSON" \
             | jq -r '.id')
    [[ -n "$new_id" && "$new_id" != "null" ]] || {
        echo "ERROR: POST succeeded but response had no .id field" >&2
        return 1
    }
    emit_comment_id "$new_id"
}

# Step 1: --comment-id → PATCH directly. Caller (e.g. /adamsreview:fix,
# /adamsreview:promote, or Phase 0 step 0.14's opt-in recovery path)
# carried the id forward from the artifact.
if [[ -n "$COMMENT_ID" ]]; then
    if patch_comment "$COMMENT_ID"; then
        trace_append "patched comment_id=$COMMENT_ID (passed via --comment-id)"
        exit 0
    fi
    # PATCH fallback: comment deleted out-of-band. Fall through to create.
    trace_append "PATCH failed for comment_id=$COMMENT_ID — falling back to POST"
    if post_comment; then exit 0; fi
    echo "ERROR: PATCH failed and POST fallback also failed" >&2
    exit 1
fi

# Step 2: no --comment-id → create a new comment. Fresh /adamsreview:review
# runs land here (each invocation is a new review event; prior comments
# on the PR are left untouched). See DESIGN §13.4.
if post_comment; then
    trace_append "created new comment on PR #$PR_NUM"
    exit 0
fi

echo "ERROR: failed to publish comment (POST returned no id)" >&2
exit 1
