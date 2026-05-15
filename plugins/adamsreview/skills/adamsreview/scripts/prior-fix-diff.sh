#!/usr/bin/env bash
# prior-fix-diff.sh — deterministic prior-fix suspect scan (Stage 2.9.C).
#
# Walks `git log -L <post-hunk>:<file>` for every hunk in the current PR's
# diff against $comparison_ref. Filters to commits whose messages match
# fix-intent patterns AND whose SHAs are reachable from $comparison_ref
# (i.e., predate the PR — the ancestor check rejects the PR's own internal
# fix commits, which would otherwise self-flag).
#
# Output is INPUT to L2's prompt, not output findings: L2 is the judge of
# whether the current diff actually reverts any suspect. False-positive
# keyword matches cost L2 prompt tokens, not false findings.
#
# Usage:
#   prior-fix-diff.sh --comparison-ref <ref> --reviewed-files <csv|@-> [--lookback-days <N>]
#
# Output (stdout): JSON array of suspect records. Empty array is valid.
#   {
#     "file": "cli/commands.ts",
#     "current_hunk_range": [175, 220],
#     "prior_fix_commit_sha": "54de955a...",
#     "prior_fix_commit_short": "54de955",
#     "prior_fix_commit_message_subject": "Fix 'Manual Accounts (manual)' label regression",
#     "prior_fix_commit_date": "2025-11-12T14:22:03-08:00",
#     "prior_fix_touched_lines": [175, 220]
#   }
#
# prior_fix_touched_lines mirrors current_hunk_range for MVP — git log -L
# selected the commit by tracking that specific range backward through
# history, so full overlap is guaranteed by construction. A future
# tightening could compute the actual intersection via `git diff-tree` on
# the prior commit, but the common case is full overlap and the field
# exists mainly as a channel for L2's prompt to reference specific lines.
#
# Stderr audit lines (one per file, matches origin-crosscheck.sh /
# comment-freshness.sh grammar):
#   prior_fix_diff: file=<path> hunks=<n> suspects=<n>
#   prior_fix_diff_skipped: file=<path> reason=<short>
#   prior_fix_diff_skipped: file=<path> hunk=[<s>,<e>] reason=log-L-failed rc=<n>
#
# Exit codes: 0 ok, 1 EXIT_VALIDATION, 5 EXIT_MISSING_DEP, 64 usage.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --comparison-ref <ref> --reviewed-files <csv|@-> [--lookback-days <N>]

Deterministic prior-fix suspect scan. For each hunk in the PR's diff
(\$comparison_ref..HEAD), emits commits reachable from \$comparison_ref
whose subject matches fix-intent keywords.

  --comparison-ref    Required. Any revspec git rev-parse can resolve.
  --reviewed-files    Required. CSV of paths, or '@-' to read newline-
                      separated paths from stdin.
  --lookback-days     Optional. Default 365. Bounds the git-log --since
                      window. git log -L still walks full file history
                      to track the range; --since only filters output.
USAGE
}

die_usage()       { echo "ERROR: $1" >&2; usage; exit 64; }
die_validation()  { echo "ERROR: $1" >&2; exit 1; }
die_missing_dep() { echo "ERROR: $1" >&2; exit 5; }

COMPARISON_REF=""
FILES_ARG=""
LOOKBACK_DAYS="365"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --comparison-ref)
            [[ $# -ge 2 ]] || die_usage "--comparison-ref requires a value"
            COMPARISON_REF="${2:-}"; shift 2 ;;
        --reviewed-files)
            [[ $# -ge 2 ]] || die_usage "--reviewed-files requires a value"
            FILES_ARG="${2:-}"; shift 2 ;;
        --lookback-days)
            [[ $# -ge 2 ]] || die_usage "--lookback-days requires a value"
            LOOKBACK_DAYS="${2:-}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$COMPARISON_REF" ]] || die_usage "--comparison-ref is required"
[[ -n "$FILES_ARG" ]]      || die_usage "--reviewed-files is required (CSV or '@-')"

command -v git >/dev/null 2>&1 || die_missing_dep "git not found on PATH"
command -v jq  >/dev/null 2>&1 || die_missing_dep "jq not found on PATH"

if ! [[ "$LOOKBACK_DAYS" =~ ^[0-9]+$ ]] || [[ "$LOOKBACK_DAYS" -lt 1 ]]; then
    die_usage "--lookback-days must be a positive integer (got '$LOOKBACK_DAYS')"
fi

# Resolve comparison ref early so error-as-prompt UX (suggestion list)
# fires before any git log cost.
if ! git rev-parse --verify --quiet "$COMPARISON_REF" >/dev/null 2>&1; then
    {
        echo "ERROR: --comparison-ref '$COMPARISON_REF' did not resolve to a commit"
        echo "Context: prior-fix-diff.sh needs a ref that git rev-parse can resolve so the --is-ancestor filter has a valid anchor."
        echo "Valid values: any revspec git understands (branch, tag, remote-tracking name, SHA)."
        echo "Did you mean:"
        git rev-parse --symbolic --branches --remotes=origin 2>/dev/null | head -10 | sed 's/^/  /'
        echo "Action: pass a resolvable ref (e.g. 'main', 'origin/main', or a full SHA)."
    } >&2
    exit 1
fi

# Compute --since boundary. Try GNU date first; fall back to BSD date
# (macOS default). Same two-shot pattern as other helpers in this tree.
if SINCE_DATE=$(date -u -d "${LOOKBACK_DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null); then
    :
elif SINCE_DATE=$(date -u -v-"${LOOKBACK_DAYS}d" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null); then
    :
else
    die_missing_dep "date: neither GNU -d nor BSD -v syntax supported on this system"
fi

# Resolve files list (CSV inline or @- stdin). tr-based split is fine —
# filenames with embedded commas are not a realistic scenario.
if [[ "$FILES_ARG" == "@-" ]]; then
    FILES_RAW="$(cat)"
else
    FILES_RAW="$FILES_ARG"
fi

FILES_LIST=()
# `|| [[ -n "$f" ]]` handles the last-line-no-newline case (CSV inline
# arg typically has no trailing newline after tr normalization).
while IFS= read -r f || [[ -n "$f" ]]; do
    [[ -z "$f" ]] && continue
    FILES_LIST+=("$f")
done < <(printf '%s' "$FILES_RAW" | tr ',' '\n')

[[ ${#FILES_LIST[@]} -gt 0 ]] || die_validation "--reviewed-files was empty after parsing (CSV or stdin produced no non-empty entries)"

out_tmp="$(mktemp)"
trap 'rm -f "$out_tmp"' EXIT

# Fix-intent boundary-aware pattern for `grep -iE`.
# [[:space:][:punct:]] is broader than the plan's `[\s\[(:-]` (punct vs.
# a specific punctuation subset) but matches more boundaries, not fewer,
# and `grep -iE` is case-insensitive so `(?i)` is not encoded.
FIX_PATTERN='(^|[[:space:][:punct:]])(fix(es|ed)?|bug|regress(ion)?|revert|restore|correct|hotfix|patch)([^[:alnum:]]|$)'

for file in "${FILES_LIST[@]}"; do
    # Skip deletion-only files: nothing at HEAD to regress into.
    if ! git cat-file -e "HEAD:$file" 2>/dev/null; then
        echo "prior_fix_diff_skipped: file=$file reason=not-in-HEAD" >&2
        continue
    fi

    # Zero-context diff — hunk headers carry post-image ranges cleanly.
    hunks_raw=$(git diff --unified=0 "${COMPARISON_REF}..HEAD" -- "$file" 2>/dev/null \
                 | grep -E '^@@ ' || true)

    if [[ -z "$hunks_raw" ]]; then
        echo "prior_fix_diff: file=$file hunks=0 suspects=0" >&2
        continue
    fi

    hunk_count=$(printf '%s\n' "$hunks_raw" | wc -l | tr -d ' ')
    file_suspect_count=0

    while IFS= read -r hunk_header; do
        # @@ -a(,b)? +c(,d)? @@ — post-image range is (c, d).
        # Missing `,d` means d=1; `,0` means pure deletion (skip).
        if [[ "$hunk_header" =~ ^@@\ -[0-9]+(,[0-9]+)?\ \+([0-9]+)(,([0-9]+))?\ @@ ]]; then
            post_start="${BASH_REMATCH[2]}"
            post_len="${BASH_REMATCH[4]:-1}"

            if [[ "$post_len" -eq 0 ]]; then
                continue
            fi

            post_end=$((post_start + post_len - 1))

            # git log -L tracks the range backward from HEAD through
            # history, following content rather than path. `--all` is
            # incompatible with -L ("More than one commit to dig from"),
            # and the HEAD-only default is the right scope anyway: we
            # want prior commits the PR's branch actually has in its
            # history. --since bounds output; the walk itself is still
            # O(file-age), accepted per plan §6 risk notes.
            log_rc=0
            log_out=$(git log --since="$SINCE_DATE" \
                -L "${post_start},${post_end}:${file}" \
                --pretty=format:'%H|%s|%cI' --no-patch 2>/dev/null) || log_rc=$?

            if [[ "$log_rc" -ne 0 ]]; then
                echo "prior_fix_diff_skipped: file=$file hunk=[${post_start},${post_end}] reason=log-L-failed rc=${log_rc}" >&2
                continue
            fi

            [[ -z "$log_out" ]] && continue

            while IFS= read -r log_line; do
                [[ -z "$log_line" ]] && continue

                # sha|subject|date. Subject may contain '|' — use positional
                # delimiters (first '|' after sha, last '|' before date).
                sha="${log_line%%|*}"
                rest="${log_line#*|}"
                subject="${rest%|*}"
                date_iso="${rest##*|}"

                if ! printf '%s' "$subject" | grep -iqE "$FIX_PATTERN"; then
                    continue
                fi

                # Filter out PR-internal fix commits: if the sha isn't an
                # ancestor of $comparison_ref, it's on the feature branch.
                # --is-ancestor exits 0 iff the first arg is an ancestor
                # of (or equal to) the second.
                if ! git merge-base --is-ancestor "$sha" "$COMPARISON_REF" 2>/dev/null; then
                    continue
                fi

                short=$(printf '%s' "$sha" | cut -c1-7)

                jq -nc \
                    --arg file "$file" \
                    --argjson hunk_start "$post_start" \
                    --argjson hunk_end "$post_end" \
                    --arg sha "$sha" \
                    --arg short "$short" \
                    --arg subject "$subject" \
                    --arg date_iso "$date_iso" \
                    '{
                        file: $file,
                        current_hunk_range: [$hunk_start, $hunk_end],
                        prior_fix_commit_sha: $sha,
                        prior_fix_commit_short: $short,
                        prior_fix_commit_message_subject: $subject,
                        prior_fix_commit_date: $date_iso,
                        prior_fix_touched_lines: [$hunk_start, $hunk_end]
                    }' >> "$out_tmp"

                file_suspect_count=$((file_suspect_count + 1))
            done <<< "$log_out"
        fi
    done <<< "$hunks_raw"

    echo "prior_fix_diff: file=$file hunks=$hunk_count suspects=$file_suspect_count" >&2
done

jq -s '.' "$out_tmp"
