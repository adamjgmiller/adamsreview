#!/usr/bin/env bash
# claude-md-paths.sh — walk-up CLAUDE.md finder (DESIGN §21.7, §23).
#
# For each input file, walk from that file's parent directory up to
# --repo-root, collecting directories that contain a CLAUDE.md. The
# repo-root CLAUDE.md (if present) is always included. Output is one
# absolute path per line, deduped, sorted by path depth (root-first).
#
# No LLM involvement — pure Bash + filesystem walk.
#
# Usage:
#   claude-md-paths.sh --repo-root <abs-path> --files <f>[,<f>...]
#   claude-md-paths.sh --repo-root <abs-path> --files @-   # read files from stdin, one per line
#
# --files accepts a comma-separated list OR "@-" to read one path per
# line from stdin (handy when the list is long enough to bump into
# ARG_MAX). Paths may be absolute or relative to --repo-root.
#
# Exits: 0 success (empty stdout is NOT an error — plenty of repos
# have no CLAUDE.md anywhere); 1 --repo-root missing, not a directory,
# or not readable; 64 usage error.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --repo-root <abs-path> --files <f>[,<f>...|@-]

Walks up from each file's parent directory to --repo-root, emitting
every ancestor that contains a CLAUDE.md. Result is deduped and
sorted root-first (so the repo-root CLAUDE.md, if any, is first).
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

REPO_ROOT=""
FILES_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)
            [[ $# -ge 2 ]] || die_usage "--repo-root requires a value"
            REPO_ROOT="${2:-}"; shift 2 ;;
        --files)
            [[ $# -ge 2 ]] || die_usage "--files requires a value"
            FILES_ARG="${2:-}"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$REPO_ROOT" ]] || die_usage "--repo-root is required"
[[ -n "$FILES_ARG" ]] || die_usage "--files is required (comma-list or @- for stdin)"

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "ERROR: --repo-root is not a directory: $REPO_ROOT" >&2
    exit 1
fi

# Realpath the root so the ancestor-containment check below works
# even when the caller passes a path with .. or symlinks.
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"

# Collect input files.
declare -a FILES=()
if [[ "$FILES_ARG" == "@-" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && FILES+=("$line")
    done
else
    # Split comma-separated list.
    IFS=',' read -r -a FILES <<< "$FILES_ARG"
fi

# Walk up from each file's parent dir to REPO_ROOT, collecting any
# CLAUDE.md found along the way. Dedup and root-first sort happen at
# the end via `sort -u` — avoids the macOS Bash 3.2 associative-array
# limitation.
{
    for f in "${FILES[@]}"; do
        if [[ "$f" = /* ]]; then
            abs="$f"
        else
            abs="$REPO_ROOT/$f"
        fi
        parent="$(dirname "$abs")"
        # Skip paths outside the repo root.
        case "$parent" in
            "$REPO_ROOT"|"$REPO_ROOT"/*) : ;;
            *) continue ;;
        esac
        cur="$parent"
        while : ; do
            if [[ -f "$cur/CLAUDE.md" ]]; then
                echo "$cur/CLAUDE.md"
            fi
            if [[ "$cur" == "$REPO_ROOT" ]] || [[ "$cur" == "/" ]]; then
                break
            fi
            cur="$(dirname "$cur")"
        done
    done

    # Always include repo-root CLAUDE.md if present (covers the case
    # where no touched file lives under a subtree with its own CLAUDE.md).
    if [[ -f "$REPO_ROOT/CLAUDE.md" ]]; then
        echo "$REPO_ROOT/CLAUDE.md"
    fi
} \
    | awk '!seen[$0]++' \
    | awk '{ n = gsub("/", "/"); print n "\t" $0 }' \
    | sort -k1,1n -k2,2 \
    | cut -f2-
