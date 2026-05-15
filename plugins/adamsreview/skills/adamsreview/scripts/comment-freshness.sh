#!/usr/bin/env bash
# comment-freshness.sh — PR-comment code-locality filter (DESIGN §21.10, §13.13).
#
# Takes a normalized bot-comment array (the shape external-scrape.sh emits)
# and filters out records whose referenced code has changed between when
# the comment was posted and HEAD. Three record kinds get three checks:
#
#   review_comment (inline, has commit_id + path):
#       git diff --name-only <commit_id>..HEAD -- <path> empty → include.
#       Non-empty → exclude (action=stale).
#
#   review (submission, has commit_id; no path — whole-PR scope):
#       git diff --name-only <commit_id>..HEAD ∩ <reviewed_files> empty
#       → include. Non-empty → exclude (action=stale).
#
#   issue_comment (no commit_id, no path — PR-level commentary):
#       Policy C2 — include iff comment.created_at is newer than the
#       latest committer.date across pulls/<pr>/commits. Matches the
#       diff-wide semantics for the case where a reviewer (e.g. Greptile)
#       posts a PR-level summary after the latest commit lands.
#
# Reachability edge case: if commit_id isn't in local history (force-push
# or shallow clone), attempt one `git fetch origin +refs/pull/<pr>/head`
# and retry. Still missing → exclude with action=unreachable.
#
# API-failure fallback: if pulls/<pr>/commits fetch fails AND any record
# is an issue_comment, emit action=api-degraded and INCLUDE all
# issue_comments unchanged (policy A fallback). Records with a real
# commit_id still get their normal check — the failure only affects the
# diff-wide path that needs the commits list.
#
# Usage:
#   comment-freshness.sh --pr <num> --reviewed-files <csv|@-> [--comments <path|@->]
#   comment-freshness.sh --fixtures-dir <dir> --reviewed-files <csv|@-> [--comments <path|@->]
#
# Only one of --reviewed-files / --comments may use @- per invocation.
#
# --fixtures-dir replays pre-fetched JSON from <dir>/pr_commits.json.
# Skips the gh call. Used by smoke tests. --pr is not required in this
# mode (no gh context needed).
#
# Input comments schema (per external-scrape.sh §21.8 output):
#   [{id, author_login, author_type, created_at, body, kind, path|null,
#     line|null, commit_id|null}, ...]
#
# Output (stdout): filtered array with the same shape. Records that pass
# the freshness check are emitted unchanged.
#
# Output (stderr): one audit line per input record
#   comment_freshness: id=<n> kind=<issue_comment|review|review_comment> \
#       action=<fresh|stale|fresh-summary|stale-summary|unreachable|api-degraded> \
#       [reason=<short>]
#
# Exits: 0 success (empty output array OK); 1 EXIT_VALIDATION (bad
# stdin JSON, missing required fields, unresolvable args); 64 usage.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage:
  $(basename "$0") --pr <num> --reviewed-files <csv|@-> [--comments <path|@->]
  $(basename "$0") --fixtures-dir <dir> --reviewed-files <csv|@-> [--comments <path|@->]

Filters a normalized PR bot-comment array by code locality (DESIGN §21.10).
Per-record audit lines land on stderr. Only one of --reviewed-files /
--comments may use @- per invocation.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }
die_validation() { echo "ERROR: $1" >&2; exit 1; }
die_missing_dep() { echo "ERROR: $1" >&2; exit 1; }

PR_NUM=""
FILES_ARG=""
COMMENTS_ARG="@-"
FIXTURES_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)
            [[ $# -ge 2 ]] || die_usage "--pr requires a value"
            PR_NUM="${2:-}"; shift 2 ;;
        --reviewed-files)
            [[ $# -ge 2 ]] || die_usage "--reviewed-files requires a value"
            FILES_ARG="${2:-}"; shift 2 ;;
        --comments)
            [[ $# -ge 2 ]] || die_usage "--comments requires a value"
            COMMENTS_ARG="${2:-}"; shift 2 ;;
        --fixtures-dir)
            [[ $# -ge 2 ]] || die_usage "--fixtures-dir requires a value"
            FIXTURES_DIR="${2:-}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$FILES_ARG" ]] || die_usage "--reviewed-files is required (csv or @- for stdin)"

if [[ -z "$FIXTURES_DIR" ]]; then
    [[ -n "$PR_NUM" ]] || die_usage "--pr is required (or use --fixtures-dir for offline mode)"
    [[ "$PR_NUM" =~ ^[0-9]+$ ]] || die_usage "--pr must be numeric, got '$PR_NUM'"
fi

# Only one of --reviewed-files / --comments may use @- per invocation —
# they both consume stdin, and mixing them silently ties the same stream
# to two readers.
if [[ "$FILES_ARG" == "@-" && "$COMMENTS_ARG" == "@-" ]]; then
    die_usage "only one of --reviewed-files / --comments may use @- per invocation"
fi

command -v git >/dev/null 2>&1 || die_missing_dep "git not found on PATH"
command -v jq  >/dev/null 2>&1 || die_missing_dep "jq not found on PATH"

if [[ -z "$FIXTURES_DIR" ]]; then
    command -v gh >/dev/null 2>&1 || die_missing_dep "gh not found on PATH (needed for pulls/<pr>/commits; use --fixtures-dir for offline testing)"
fi

# ---------------------------------------------------------------- load inputs

# Reviewed-files list (set of paths for intersection on review submissions).
REVIEWED_FILES_TMP=$(mktemp -t comment-freshness-files.XXXXXX)
trap 'rm -f "$REVIEWED_FILES_TMP"' EXIT

if [[ "$FILES_ARG" == "@-" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && printf '%s\n' "$line"
    done > "$REVIEWED_FILES_TMP"
else
    printf '%s' "$FILES_ARG" | tr ',' '\n' | awk 'NF>0' > "$REVIEWED_FILES_TMP"
fi

# Comments array (stdin, file, or inline JSON).
if [[ "$COMMENTS_ARG" == "@-" ]]; then
    COMMENTS_JSON="$(cat)"
elif [[ "${COMMENTS_ARG:0:1}" == "@" ]]; then
    path="${COMMENTS_ARG:1}"
    [[ -r "$path" ]] || die_validation "comments file not readable: $path"
    COMMENTS_JSON="$(cat "$path")"
elif [[ -f "$COMMENTS_ARG" && "${COMMENTS_ARG:0:1}" != "[" && "${COMMENTS_ARG:0:1}" != "{" ]]; then
    COMMENTS_JSON="$(cat "$COMMENTS_ARG")"
else
    COMMENTS_JSON="$COMMENTS_ARG"
fi

# Validate shape — must be a JSON array.
if ! echo "$COMMENTS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die_validation "--comments must parse as a JSON array; got $(echo "$COMMENTS_JSON" | jq -r 'type' 2>/dev/null || echo 'unparseable JSON')"
fi

N=$(echo "$COMMENTS_JSON" | jq 'length')

# ---------------------------------------------------------------- commits list
# Only fetched if any input record needs the diff-wide timestamp compare
# (kind=issue_comment or commit_id=null). Lazy-loaded below.

PR_COMMITS_JSON=""
PR_COMMITS_FETCHED=""  # "ok" | "failed" | ""  (empty = not yet attempted)

fetch_pr_commits() {
    # Sets PR_COMMITS_JSON + PR_COMMITS_FETCHED. Idempotent.
    if [[ -n "$PR_COMMITS_FETCHED" ]]; then return; fi
    if [[ -n "$FIXTURES_DIR" ]]; then
        local f="$FIXTURES_DIR/pr_commits.json"
        if [[ -r "$f" ]]; then
            PR_COMMITS_JSON="$(cat "$f")"
            # Validate shape.
            if ! echo "$PR_COMMITS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
                PR_COMMITS_FETCHED="failed"
                echo "comment_freshness_api_failed: fixture $f is not a JSON array" >&2
                return
            fi
            PR_COMMITS_FETCHED="ok"
        else
            PR_COMMITS_FETCHED="failed"
            echo "comment_freshness_api_failed: fixture $f not readable" >&2
        fi
        return
    fi

    local owner_repo
    if ! owner_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null); then
        PR_COMMITS_FETCHED="failed"
        echo "comment_freshness_api_failed: gh repo view failed (run 'gh auth status')" >&2
        return
    fi

    local api_err="$(mktemp)"
    if ! PR_COMMITS_JSON=$(gh api --paginate "repos/$owner_repo/pulls/$PR_NUM/commits" 2>"$api_err"); then
        PR_COMMITS_FETCHED="failed"
        local excerpt
        excerpt=$(head -c 200 "$api_err" | tr '\n' ' ')
        echo "comment_freshness_api_failed: gh api pulls/$PR_NUM/commits: $excerpt" >&2
        rm -f "$api_err"
        return
    fi
    rm -f "$api_err"

    # --paginate emits concatenated arrays; merge into one.
    if ! PR_COMMITS_JSON=$(echo "$PR_COMMITS_JSON" | jq -s 'add // []' 2>/dev/null); then
        PR_COMMITS_FETCHED="failed"
        echo "comment_freshness_api_failed: could not merge paginated commits output" >&2
        return
    fi

    PR_COMMITS_FETCHED="ok"
}

# max_committer_date: emit the max .commit.committer.date (ISO-8601) on
# stdout, or empty if no commits. Reads PR_COMMITS_JSON.
max_committer_date() {
    echo "$PR_COMMITS_JSON" \
        | jq -r '[.[] | .commit.committer.date] | sort | last // ""'
}

# ---------------------------------------------------------------- per-record loop

out_tmp="$(mktemp)"
# Extend the existing trap so both tempfiles get cleaned up.
trap 'rm -f "$REVIEWED_FILES_TMP" "$out_tmp"' EXIT

# Cache of commit_id → reachability ("ok" | "missing"). A single PR often
# has many comments pinned to the same commit_id; caching avoids redundant
# fetches / cat-file calls.
COMMIT_REACH_TMP=$(mktemp)
trap 'rm -f "$REVIEWED_FILES_TMP" "$out_tmp" "$COMMIT_REACH_TMP"' EXIT

commit_reachable() {
    # Echoes "ok" or "missing" on stdout. Caches per commit_id.
    local sha="$1"
    local cached
    cached=$(awk -v s="$sha" '$1 == s { print $2; exit }' "$COMMIT_REACH_TMP")
    if [[ -n "$cached" ]]; then
        echo "$cached"
        return
    fi

    if git cat-file -e "${sha}^{commit}" 2>/dev/null; then
        echo "$sha ok" >> "$COMMIT_REACH_TMP"
        echo "ok"
        return
    fi

    # Attempt one fetch (skipped in fixtures mode — no network).
    if [[ -z "$FIXTURES_DIR" && -n "$PR_NUM" ]]; then
        git fetch --quiet origin "+refs/pull/$PR_NUM/head:refs/adams-review/pr-$PR_NUM" 2>/dev/null || true
        if git cat-file -e "${sha}^{commit}" 2>/dev/null; then
            echo "$sha ok" >> "$COMMIT_REACH_TMP"
            echo "ok"
            return
        fi
    fi

    echo "$sha missing" >> "$COMMIT_REACH_TMP"
    echo "missing"
}

# emit: append a JSON record to out_tmp (one object per line; wrapped into
# an array at end-of-script). Called only when we decide to INCLUDE.
emit() {
    echo "$1" >> "$out_tmp"
}

# audit: print one stderr line. reason is optional.
audit() {
    local id="$1" kind="$2" action="$3" reason="${4:-}"
    if [[ -n "$reason" ]]; then
        echo "comment_freshness: id=$id kind=$kind action=$action reason=$reason" >&2
    else
        echo "comment_freshness: id=$id kind=$kind action=$action" >&2
    fi
}

for (( i = 0; i < N; i++ )); do
    rec=$(echo "$COMMENTS_JSON" | jq -c ".[$i]")
    rid=$(echo "$rec" | jq -r '.id // ("idx-" + ('"$i"' | tostring))')
    rkind=$(echo "$rec" | jq -r '.kind // ""')
    rcommit=$(echo "$rec" | jq -r '.commit_id // ""')
    rpath=$(echo "$rec" | jq -r '.path // ""')
    rcreated=$(echo "$rec" | jq -r '.created_at // ""')

    # ------------ branch: diff-wide (issue_comment OR missing commit_id)
    if [[ "$rkind" == "issue_comment" || -z "$rcommit" ]]; then
        fetch_pr_commits
        if [[ "$PR_COMMITS_FETCHED" == "failed" ]]; then
            # Policy A fallback — include.
            emit "$rec"
            audit "$rid" "$rkind" "api-degraded" "pr_commits-fetch-failed"
            continue
        fi

        latest=$(max_committer_date)
        if [[ -z "$latest" ]]; then
            # No commits on the PR — nothing can have shifted since comment.
            emit "$rec"
            audit "$rid" "$rkind" "fresh-summary" "no-commits"
            continue
        fi

        if [[ -z "$rcreated" ]]; then
            # No created_at → can't compare; conservative: exclude.
            audit "$rid" "$rkind" "stale-summary" "missing-created_at"
            continue
        fi

        # Compare ISO-8601 UTC timestamps as epoch seconds via jq
        # (avoids date-parser differences between macOS / Linux).
        cmp=$(jq -rn \
            --arg a "$rcreated" \
            --arg b "$latest" \
            '( ($a | fromdateiso8601) > ($b | fromdateiso8601) )')

        if [[ "$cmp" == "true" ]]; then
            emit "$rec"
            audit "$rid" "$rkind" "fresh-summary" "newer-than-latest-commit"
        else
            audit "$rid" "$rkind" "stale-summary" "latest-commit-newer"
        fi
        continue
    fi

    # ------------ branch: commit_id present
    reach=$(commit_reachable "$rcommit")
    if [[ "$reach" == "missing" ]]; then
        audit "$rid" "$rkind" "unreachable" "commit_id-not-in-history"
        continue
    fi

    if [[ -n "$rpath" && "$rkind" == "review_comment" ]]; then
        # Inline review comment — check just the file the comment is attached to.
        diff_out=$(git diff --name-only "${rcommit}..HEAD" -- "$rpath" 2>/dev/null || true)
        if [[ -z "$diff_out" ]]; then
            emit "$rec"
            audit "$rid" "$rkind" "fresh" "path-unchanged"
        else
            audit "$rid" "$rkind" "stale" "path-touched"
        fi
    else
        # Review submission (no path) — intersect diff with reviewed_files.
        changed_tmp=$(mktemp)
        git diff --name-only "${rcommit}..HEAD" 2>/dev/null > "$changed_tmp" || true
        if [[ ! -s "$changed_tmp" ]]; then
            emit "$rec"
            audit "$rid" "$rkind" "fresh" "no-diff"
            rm -f "$changed_tmp"
            continue
        fi

        # awk intersection — portable vs comm/grep -Ff (see staleness.sh).
        inter=$(awk 'NR==FNR { seen[$0]=1; next } ($0 in seen)' \
            "$REVIEWED_FILES_TMP" "$changed_tmp")
        rm -f "$changed_tmp"

        if [[ -z "$inter" ]]; then
            emit "$rec"
            audit "$rid" "$rkind" "fresh" "no-reviewed-file-touched"
        else
            audit "$rid" "$rkind" "stale" "reviewed-file-touched"
        fi
    fi
done

# ---------------------------------------------------------------- emit array

# Wrap the per-line objects back into an array (one object per non-empty line).
# If out_tmp is empty, emit [].
if [[ -s "$out_tmp" ]]; then
    jq -s '.' "$out_tmp"
else
    echo "[]"
fi
