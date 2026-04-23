#!/usr/bin/env bash
# staleness.sh — file-overlap staleness classifier (DESIGN §21.4, §13.3).
#
# Decides whether a code review is still "fresh" relative to the current
# HEAD by intersecting the files changed since the reviewed SHA with a
# caller-supplied list of reviewed files (artifact.reviewed_files_all;
# the full safety envelope — every file in the review-time diff, not
# just files that produced findings, see §13.3).
#
# Usage:
#   staleness.sh --reviewed-sha <sha> --reviewed-files <f>[,<f>...]
#   staleness.sh --reviewed-sha <sha> --reviewed-files @-   # read files from stdin, one per line
#
# Classifications (§21.4):
#   safe    HEAD == reviewed_sha. stdout: `safe`. exit 0.
#   warn    HEAD moved, but no reviewed files touched. stdout: `warn: ...`. exit 0.
#   unsafe  HEAD moved AND one or more reviewed files touched. stderr:
#           `unsafe: files <list> changed since review; re-run /adamsreview:review or use --force`.
#           exit 1.
#
# Other exits: 1 on git error / unreachable SHA (both treated as "can't
# prove safe" → same exit as unsafe). 64 on usage error.
#
# Git is invoked from the current working directory; callers cd first.
# @- mode reads one path per line from stdin for large --reviewed-files
# lists (reviewed_files_all can exceed ARG_MAX on big diffs).

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --reviewed-sha <sha> --reviewed-files <f>[,<f>...|@-]

Classifies current HEAD relative to a reviewed SHA:
  safe    HEAD == reviewed_sha
  warn    HEAD moved but no reviewed files changed
  unsafe  HEAD moved AND reviewed files changed

--reviewed-files accepts a comma-separated list OR "@-" to read one
path per line from stdin (use this when the list is long enough to
approach ARG_MAX).
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

REVIEWED_SHA=""
FILES_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reviewed-sha)
            [[ $# -ge 2 ]] || die_usage "--reviewed-sha requires a value"
            REVIEWED_SHA="${2:-}"; shift 2 ;;
        --reviewed-files)
            [[ $# -ge 2 ]] || die_usage "--reviewed-files requires a value"
            FILES_ARG="${2:-}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$REVIEWED_SHA" ]] || die_usage "--reviewed-sha is required"
[[ -n "$FILES_ARG" ]]    || die_usage "--reviewed-files is required (comma-list or @- for stdin)"

# Must be inside a git repo with at least one commit.
if ! HEAD=$(git rev-parse HEAD 2>/dev/null); then
    echo "ERROR: not inside a git repo, or repo has no commits (git rev-parse HEAD failed)" >&2
    echo "Action: cd into the repo the review was run against before calling staleness.sh." >&2
    exit 1
fi

# Resolve the reviewed sha and verify it's reachable from HEAD. A shallow
# clone or force-push can leave the SHA unknown; treat that the same as
# unsafe rather than silently comparing to an unknown-history point.
if ! REVIEWED_RESOLVED=$(git rev-parse --verify "${REVIEWED_SHA}^{commit}" 2>/dev/null); then
    echo "ERROR: reviewed sha '$REVIEWED_SHA' is not known to this repo" >&2
    echo "Possible causes: shallow clone, force-push rewrote history, or the review ran in a different repo." >&2
    echo "Action: re-run /adamsreview:review to regenerate the review against the current history." >&2
    exit 1
fi

if ! git merge-base --is-ancestor "$REVIEWED_RESOLVED" HEAD 2>/dev/null; then
    echo "ERROR: reviewed sha '$REVIEWED_SHA' is not reachable from HEAD" >&2
    echo "The branch has likely been rebased or force-pushed since the review was generated." >&2
    echo "Action: re-run /adamsreview:review against the current branch." >&2
    exit 1
fi

# Fast path: HEAD hasn't moved.
if [[ "$HEAD" == "$REVIEWED_RESOLVED" ]]; then
    echo "safe"
    exit 0
fi

# Slow path: collect the reviewed-files list and intersect with the
# git diff. tmp files live under TMPDIR (macOS default: /var/folders/...).
REVIEWED_LIST=$(mktemp -t staleness-reviewed.XXXXXX)
CHANGED_LIST=$(mktemp -t staleness-changed.XXXXXX)
trap 'rm -f "$REVIEWED_LIST" "$CHANGED_LIST"' EXIT

if [[ "$FILES_ARG" == "@-" ]]; then
    # One path per line; skip blanks.
    while IFS= read -r line; do
        [[ -n "$line" ]] && printf '%s\n' "$line"
    done > "$REVIEWED_LIST"
else
    # Comma-separated; split.
    printf '%s' "$FILES_ARG" | tr ',' '\n' | awk 'NF>0' > "$REVIEWED_LIST"
fi

# The set of files touched between the reviewed sha and HEAD.
git diff --name-only "$REVIEWED_RESOLVED..HEAD" > "$CHANGED_LIST"

# Intersection: files present in BOTH lists. Portable awk (Bash 3.2-safe;
# no `comm` which requires sorted input; no `grep -Ff` which is fragile
# with filenames containing regex metacharacters).
INTERSECTION=$(awk 'NR==FNR { seen[$0]=1; next } ($0 in seen)' "$REVIEWED_LIST" "$CHANGED_LIST")

if [[ -z "$INTERSECTION" ]]; then
    echo "warn: branch moved but no reviewed files changed"
    exit 0
fi

# Dedup and format (one run may rename a file twice; git diff shows the
# net path, but an explicit unique-sort is cheap insurance).
UNIQUE=$(printf '%s\n' "$INTERSECTION" | awk '!seen[$0]++')
COMMA_LIST=$(printf '%s\n' "$UNIQUE" | paste -sd, -)

echo "unsafe: files $COMMA_LIST changed since review; re-run /adamsreview:review or use --force" >&2
exit 1
