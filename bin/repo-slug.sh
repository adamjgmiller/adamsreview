#!/usr/bin/env bash
# repo-slug.sh — canonical repo-slug derivation (DESIGN §9.2).
#
# Single source of truth for the directory-name slug used under
# `$ADAMS_REVIEW_REVIEWS_ROOT` (or `~/.adams-reviews`). Called by
# Phase 0 (preflight) and Phase 7 (fix-loader); see also the
# §25.1 working-set entry for `repo_slug`.
#
# Algorithm (remote URL):
#   1. `git -C <repo-root> remote get-url origin`
#   2. strip scheme (`^[A-Za-z]+://`)
#   3. strip `^git@`
#   4. replace first `:` with `/`  (git@host:path → host/path)
#   5. strip trailing `.git`        (←— the step prose readers miss)
#   6. lowercase
#   7. replace `/` with `-`
#   8. substitute any remaining non-`[a-z0-9._-]` with `_`
#
# Fallback (no origin remote): `local-` + sanitized absolute repo
# root. `sanitized` = the same non-`[a-z0-9._-]` → `_` substitution,
# then lowercase (matching the pre-helper Phase 7 order so existing
# local-mode directories keep resolving).
#
# Usage:
#   repo-slug.sh --repo-root <abs-path>
#
# Exits: 0 success (slug printed to stdout, one line); 1 --repo-root
# missing or not a directory; 64 usage error.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --repo-root <abs-path>

Prints the canonical DESIGN §9.2 repo slug for <abs-path> to stdout.
Derivation uses \`git remote get-url origin\` when present; otherwise
falls back to a sanitized \`local-<path>\` form.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

REPO_ROOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)
            [[ $# -ge 2 ]] || die_usage "--repo-root requires a value"
            REPO_ROOT="${2:-}"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$REPO_ROOT" ]] || die_usage "--repo-root is required"

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "ERROR: --repo-root is not a directory: $REPO_ROOT" >&2
    exit 1
fi

remote_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"

if [[ -n "$remote_url" ]]; then
    # Order matters: lowercase AFTER the structural edits so the regex
    # anchors (`^git@`, `\.git$`) operate on the original string shape
    # but the output is already lowercase before the final `_` pass.
    slug="$(printf '%s' "$remote_url" \
        | sed -E 's#^[A-Za-z]+://##; s#^git@##; s#:#/#; s#\.git$##' \
        | tr 'A-Z' 'a-z' \
        | tr '/' '-' \
        | sed -E 's#[^a-z0-9._-]#_#g')"
else
    # Preserve pre-helper Phase 7 ordering (sanitize first, then
    # lowercase) so existing local-mode directories keep resolving.
    slug="local-$(printf '%s' "$REPO_ROOT" \
        | sed -E 's#[^a-z0-9._-]#_#g' \
        | tr 'A-Z' 'a-z')"
fi

printf '%s\n' "$slug"
