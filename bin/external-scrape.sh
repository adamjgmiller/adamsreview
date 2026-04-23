#!/usr/bin/env bash
# external-scrape.sh — Phase 1.5 bot-comment scraper (DESIGN §21.8, §13.8).
#
# Queries the three GitHub PR comment endpoints in parallel, filters to
# bot authors, applies the allow/deny policy from the user config, and
# emits a normalized JSON array to stdout suitable for the Phase 1.5
# Sonnet normalizer (§19.2a).
#
# Code-locality (freshness) filtering is NOT done here — pipe this
# helper's output into comment-freshness.sh (§21.10) for that. Stage 2.8
# removed the `--since` time-window filter that used to live at this
# layer; code locality (not newness) is the right axis for relevance,
# and running that decision on the full unfiltered set is simpler to
# reason about than two filters in series at different layers.
#
# Usage:
#   external-scrape.sh --pr <num> [--config <path>]
#   external-scrape.sh --fixtures-dir <dir>    (offline replay)
#
# --config overrides the config-precedence chain (useful for testing).
# --fixtures-dir replays pre-fetched endpoint outputs from
#   <dir>/issue_comments.json, <dir>/reviews.json, <dir>/review_comments.json
# (missing files default to []). Skips all gh calls — useful for smoke
# tests and ad-hoc rescoring of scraped data. Current user is read from
# $ADAMS_REVIEW_FIXTURES_USER (default $(whoami)).
# Default chain (first found wins):
#   .claude/review-config.json                      (per-repo, cwd-relative)
#   $ADAMS_REVIEW_CONFIG_ROOT/review-config.json    (override for tests)
#   ~/.adams-reviews/review-config.json             (global)
#
# Config shape (all keys optional):
#   {
#     "external_reviewer_bots": {
#       "allow": null | ["login1", ...],    // null => allow-all-except-deny
#       "deny":  ["dependabot[bot]", ...]   // REPLACES the default list when set
#     }
#   }
#
# Default deny list (when config has no 'deny'): dependabot[bot],
# renovate[bot], github-actions[bot], codecov[bot]. These are
# automation/status bots, not reviewers.
#
# Output schema (one object per comment; array order preserved from the
# raw API responses):
#   [
#     {
#       "id": 12345,
#       "author_login": "coderabbit-ai[bot]",
#       "author_type": "Bot",
#       "created_at": "2026-04-17T18:02:10Z",
#       "body": "...",
#       "kind": "issue_comment" | "review" | "review_comment",
#       "path": "src/auth/session.ts" | null,
#       "line": 42 | null,
#       "commit_id": "abc123..." | null
#     },
#     ...
#   ]
#
# Reviews without a body (e.g. plain APPROVED) are retained — the
# downstream normalizer decides whether they're actionable. Only the
# bot/time/allow/deny filters apply here.
#
# Exits: 0 success (even when zero results); 1 gh error (rate limit,
# network, auth); 64 usage.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage:
  $(basename "$0") --pr <num> [--config <path>]
  $(basename "$0") --fixtures-dir <dir>    (offline replay)

Queries GitHub for bot-authored comments on a PR, applies the
external_reviewer_bots allow/deny config, and emits a normalized JSON
array to stdout. Pipe into comment-freshness.sh (§21.10) to drop
records whose referenced code has changed since posting.

--fixtures-dir replays pre-fetched JSON from a directory — used by smoke
tests and ad-hoc replays. No gh calls in that mode.

Exits 0 on success (empty array if no bot comments). Exits 1 on gh
errors (rate limit surfaced with reset time when parseable).
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

PR_NUM=""
CONFIG_OVERRIDE=""
FIXTURES_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)
            [[ $# -ge 2 ]] || die_usage "--pr requires a value"
            PR_NUM="${2:-}"; shift 2 ;;
        --config)
            [[ $# -ge 2 ]] || die_usage "--config requires a value"
            CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
        --fixtures-dir)
            [[ $# -ge 2 ]] || die_usage "--fixtures-dir requires a value"
            FIXTURES_DIR="${2:-}"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *) die_usage "unknown arg '$1'" ;;
    esac
done

if [[ -z "$FIXTURES_DIR" ]]; then
    [[ -n "$PR_NUM" ]] || die_usage "--pr is required (or use --fixtures-dir for offline testing)"
    [[ "$PR_NUM" =~ ^[0-9]+$ ]] || die_usage "--pr must be numeric, got '$PR_NUM'"
fi

# ------------------------------------------------------------------ config

DEFAULT_DENY='["dependabot[bot]","renovate[bot]","github-actions[bot]","codecov[bot]"]'

resolve_config_path() {
    if [[ -n "$CONFIG_OVERRIDE" ]]; then
        echo "$CONFIG_OVERRIDE"
        return
    fi
    if [[ -f ".claude/review-config.json" ]]; then
        echo ".claude/review-config.json"
        return
    fi
    local test_root="${ADAMS_REVIEW_CONFIG_ROOT:-}"
    if [[ -n "$test_root" && -f "$test_root/review-config.json" ]]; then
        echo "$test_root/review-config.json"
        return
    fi
    if [[ -f "$HOME/.adams-reviews/review-config.json" ]]; then
        echo "$HOME/.adams-reviews/review-config.json"
        return
    fi
    echo ""
}

CONFIG_PATH=$(resolve_config_path)

if [[ -n "$CONFIG_PATH" ]]; then
    if ! ALLOW=$(jq -c '.external_reviewer_bots.allow // null' "$CONFIG_PATH" 2>/dev/null); then
        echo "ERROR: failed to parse config at $CONFIG_PATH" >&2
        echo "Action: validate the file is well-formed JSON (jq . $CONFIG_PATH)." >&2
        exit 1
    fi
    DENY=$(jq -c ".external_reviewer_bots.deny // $DEFAULT_DENY" "$CONFIG_PATH")
else
    ALLOW="null"
    DENY="$DEFAULT_DENY"
fi

WORK=$(mktemp -d -t adams-review-scrape.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

ISSUE_OUT="$WORK/issue_comments.json"
REVIEW_OUT="$WORK/reviews.json"
RVCMT_OUT="$WORK/review_comments.json"

if [[ -n "$FIXTURES_DIR" ]]; then
    # Offline mode — read pre-fetched JSON from a fixtures dir. Used for
    # unit-level smoke tests and ad-hoc replays. Each file must be a
    # JSON array (possibly empty); missing files are treated as [].
    CURRENT_USER="${ADAMS_REVIEW_FIXTURES_USER:-$(whoami)}"
    for name in issue_comments reviews review_comments; do
        if [[ -f "$FIXTURES_DIR/$name.json" ]]; then
            cp "$FIXTURES_DIR/$name.json" "$WORK/$name.json"
        else
            echo '[]' > "$WORK/$name.json"
        fi
    done
else
    # ------------------------------------------------------------------ gh context

    if ! OWNER_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null); then
        echo "ERROR: could not resolve owner/repo via 'gh repo view'" >&2
        echo "Action: run 'gh auth status'; if unauthenticated, 'gh auth login'. Verify 'gh repo view' works in this directory." >&2
        exit 1
    fi

    if ! CURRENT_USER=$(gh api user -q .login 2>/dev/null); then
        echo "ERROR: could not resolve current gh user via 'gh api user'" >&2
        echo "Action: run 'gh auth status' to verify authentication." >&2
        exit 1
    fi

    # ------------------------------------------------------------------ fetch

    ISSUE_ERR="$WORK/issue_comments.err"
    REVIEW_ERR="$WORK/reviews.err"
    RVCMT_ERR="$WORK/review_comments.err"

    # Fetch all three endpoints in parallel. --paginate so we see all
    # comments on long-running PRs.
    gh api --paginate "repos/$OWNER_REPO/issues/$PR_NUM/comments" >"$ISSUE_OUT" 2>"$ISSUE_ERR" &
    ISSUE_PID=$!
    gh api --paginate "repos/$OWNER_REPO/pulls/$PR_NUM/reviews" >"$REVIEW_OUT" 2>"$REVIEW_ERR" &
    REVIEW_PID=$!
    gh api --paginate "repos/$OWNER_REPO/pulls/$PR_NUM/comments" >"$RVCMT_OUT" 2>"$RVCMT_ERR" &
    RVCMT_PID=$!

    FAIL=0
    wait "$ISSUE_PID"  || FAIL=1
    wait "$REVIEW_PID" || FAIL=1
    wait "$RVCMT_PID"  || FAIL=1

    if [[ "$FAIL" -ne 0 ]]; then
        echo "ERROR: one or more GitHub endpoints failed" >&2
        for label in "issue-comments:$ISSUE_ERR" "reviews:$REVIEW_ERR" "review-comments:$RVCMT_ERR"; do
            path="${label#*:}"
            name="${label%:*}"
            if [[ -s "$path" ]]; then
                echo "--- $name ---" >&2
                # gh puts rate-limit info in stderr — surface directly.
                cat "$path" >&2
            fi
        done
        # Try to pull a reset time for the common rate-limit case.
        if grep -qi "rate limit" "$ISSUE_ERR" "$REVIEW_ERR" "$RVCMT_ERR" 2>/dev/null; then
            echo "Action: wait for the rate limit to reset (see 'X-RateLimit-Reset' headers above), or re-run /adamsreview:review without --ensemble." >&2
        else
            echo "Action: run 'gh auth status'; check network; retry." >&2
        fi
        exit 1
    fi
fi

# ------------------------------------------------------------------ normalize + filter

# Each endpoint's records map to a common schema. The three endpoints
# differ in field naming:
#   issue_comments:  id, user, created_at, body
#   reviews:         id, user, submitted_at, body (nullable), commit_id, state
#   review_comments: id, user, created_at, body, commit_id, path, line (or original_line)
#
# For "reviews", we use submitted_at as the time anchor (created_at is
# absent). For "review_comments", we fall back from line → original_line
# when the line the comment was attached to has shifted since submission.

jq -s \
    --argjson allow "$ALLOW" \
    --argjson deny "$DENY" \
    --arg current_user "$CURRENT_USER" \
    '
    def is_bot_login: test("\\[bot\\]$");

    # Normalize each endpoint.
    def norm_issue:
      map({
        id: .id,
        author_login: .user.login,
        author_type: .user.type,
        created_at: .created_at,
        body: .body,
        kind: "issue_comment",
        path: null,
        line: null,
        commit_id: null
      });
    def norm_review:
      map({
        id: .id,
        author_login: .user.login,
        author_type: .user.type,
        created_at: .submitted_at,
        body: .body,
        kind: "review",
        path: null,
        line: null,
        commit_id: .commit_id
      });
    def norm_review_comment:
      map({
        id: .id,
        author_login: .user.login,
        author_type: .user.type,
        created_at: .created_at,
        body: .body,
        kind: "review_comment",
        path: .path,
        line: (.line // .original_line),
        commit_id: .commit_id
      });

    (.[0] | norm_issue) + (.[1] | norm_review) + (.[2] | norm_review_comment)
    | map(. as $c | select(
        # bot (Bot type OR [bot] suffix)
        ($c.author_type == "Bot" or ($c.author_login | is_bot_login))
        # not the current gh user (skip self-authored review comments)
        and $c.author_login != $current_user
        # deny list (piping $deny rebinds . — hence $c capture above)
        and (($deny | index($c.author_login)) == null)
        # optional strict allow list
        and ( $allow == null or (($allow | index($c.author_login)) != null) )
      ))
    ' \
    "$ISSUE_OUT" "$REVIEW_OUT" "$RVCMT_OUT"
