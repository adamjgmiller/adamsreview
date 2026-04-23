#!/usr/bin/env bash
# line-range-check.sh — Phase 1 join-step sanity filter for lens-supplied
# line ranges.
#
# Background: L5-ux (and occasionally other Sonnet lenses) have been
# observed fabricating `line_range` values well past the actual file
# length — e.g. claiming 1815-1826 in a 1042-line file. Phase 4
# validators re-search the file for the claim pattern, so the finding
# can still "confirm" and reach the rendered report with unreachable
# line numbers. This helper catches the hallucination at the pool
# boundary instead.
#
# Input: a pooled candidate JSON array on stdin (same shape Phase 1
# step 1.5 feeds to assign-finding-ids.sh — sources[] already present,
# no .id yet). Must run with the working directory inside the repo so
# `git show $ref:<path>` resolves.
#
# For each candidate:
#   - file == "(unknown)" (Phase 1.5 external-scrape sentinel)     → passed through
#   - file missing at $reviewed_sha                                 → dropped + trace
#   - line_range[1] > actual line count at $reviewed_sha            → dropped + trace
#   - otherwise                                                    → passed through
#
# Dropped candidates never block the run — the surviving array is
# emitted on stdout and the reasons land on stderr. The caller tees
# stderr into trace.md.
#
# Audit lines on stderr (one per dropped candidate):
#   lens_hallucinated_line_range: source=<src> file=<path> range=[a,b] actual_lines=<N>
#   lens_referenced_missing_file: source=<src> file=<path>
#
# Usage:
#   echo "$pooled" | line-range-check.sh --reviewed-sha <ref>
#
# Exits: 0 success; 1 EXIT_VALIDATION (bad ref, bad JSON);
#        5 EXIT_MISSING_DEP (no git, no jq); 64 usage.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --reviewed-sha <ref>

Reads a pooled candidate JSON array from stdin and drops entries whose
line_range[1] overshoots the referenced file at <ref>, or whose file
is missing at <ref>. file=="(unknown)" sentinels pass through.
Per-drop audit lines land on stderr.
USAGE
}

die_usage()       { echo "ERROR: $1" >&2; usage; exit 64; }
die_validation()  { echo "ERROR: $1" >&2; exit 1; }
die_missing_dep() { echo "ERROR: $1" >&2; exit 5; }

REVIEWED_SHA=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reviewed-sha)
            [[ $# -ge 2 ]] || die_usage "--reviewed-sha requires a value"
            REVIEWED_SHA="${2:-}"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$REVIEWED_SHA" ]] || die_usage "--reviewed-sha is required"

command -v git >/dev/null 2>&1 || die_missing_dep "git not found on PATH"
command -v jq  >/dev/null 2>&1 || die_missing_dep "jq not found on PATH"

# Validate the ref up-front — error-as-prompt per §8.6. Mirrors
# origin-crosscheck.sh so failure modes stay consistent across Phase 1
# join-step helpers.
if ! git rev-parse --verify --quiet "$REVIEWED_SHA" >/dev/null 2>&1; then
    {
        echo "ERROR: --reviewed-sha '$REVIEWED_SHA' did not resolve to a commit"
        echo "Context: line-range-check.sh needs a ref that git rev-parse can resolve so per-file line counts have a valid anchor."
        echo "Valid values: any revspec git understands (HEAD, branch name, SHA)."
        echo "Did you mean:"
        git rev-parse --symbolic --branches 2>/dev/null | head -5 | sed 's/^/  /'
        echo "Action: pass a ref that resolves at this cwd (e.g. 'HEAD' or the Phase-0 \$reviewed_sha)."
    } >&2
    exit 1
fi

INPUT="$(cat)"
if ! echo "$INPUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die_validation "stdin must parse as a JSON array; got $(echo "$INPUT" | jq -r 'type' 2>/dev/null || echo 'unparseable JSON')"
fi

N=$(echo "$INPUT" | jq 'length')

out_tmp="$(mktemp)"
trap 'rm -f "$out_tmp"' EXIT

for (( i = 0; i < N; i++ )); do
    cand=$(echo "$INPUT" | jq ".[$i]")
    file=$(echo "$cand" | jq -r '.file // ""')
    start=$(echo "$cand" | jq -r '.line_range[0] // 0')
    end=$(echo "$cand"   | jq -r '.line_range[1] // 0')
    src=$(echo "$cand"   | jq -r '.sources[0] // "unknown"')

    # Phase 1.5 external-scrape sentinel — pass through untouched. These
    # candidates carry a real claim with a missing file location; the
    # downstream renderer already handles them.
    if [[ "$file" == "(unknown)" ]]; then
        echo "$cand" >> "$out_tmp"
        continue
    fi

    # Defensive: if file/line_range is malformed, let it through — the
    # jq builder at step 1.5 or the schema validator at --add-finding
    # will catch it with a more specific error. This helper's job is
    # hallucinated-range detection, not general schema enforcement.
    if [[ -z "$file" || "$start" == "0" || "$end" == "0" ]]; then
        echo "$cand" >> "$out_tmp"
        continue
    fi

    # File existence at $reviewed_sha. `git cat-file -e` exits non-zero
    # on a missing path (same check origin-crosscheck uses).
    if ! git cat-file -e "$REVIEWED_SHA:$file" 2>/dev/null; then
        echo "lens_referenced_missing_file: source=$src file=$file" >&2
        continue
    fi

    # Count lines at the reviewed ref. `git show REF:path` streams the
    # blob; `awk 'END{print NR}'` counts records so files without a
    # trailing newline don't undercount by 1 (which would cause false-
    # positive drops for findings ranging to the last visible line).
    actual_lines=$(git show "$REVIEWED_SHA:$file" 2>/dev/null | awk 'END{print NR}')
    if [[ -z "$actual_lines" ]]; then
        # Unreadable blob (shouldn't happen post cat-file success) —
        # let it through, same policy as malformed ranges above.
        echo "$cand" >> "$out_tmp"
        continue
    fi

    if (( end > actual_lines )); then
        echo "lens_hallucinated_line_range: source=$src file=$file range=[$start,$end] actual_lines=$actual_lines" >&2
        continue
    fi

    echo "$cand" >> "$out_tmp"
done

# Wrap the per-line objects back into an array.
jq -s '.' "$out_tmp"
