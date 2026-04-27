#!/usr/bin/env bash
# branch-behind-base.sh — preflight check for the rotated staleness axis:
# has $base_branch (or origin/$base_branch) moved forward since the
# review branch was cut?
#
# Companion to freshness-gate.sh:
#   - freshness-gate.sh covers local_base ↔ remote_base (Phase 0.2a).
#   - this helper covers HEAD     ↔ comparison_ref (Phase 0.6a / 7.6a / :add 3a).
#
# When HEAD is behind $comparison_ref, three things can go wrong:
#   1. Phantom deletions in the lens diff (two-dot semantics).
#   2. Stale review baseline — base may have shifted code the branch
#      calls into (renames, API changes, dep bumps).
#   3. Latent merge conflicts.
#
# Two modes. Mutually exclusive.
#
#   passive (--comparison-ref <ref>)
#     Caller already has a resolved comparison_ref (e.g., :review's
#     freshness-gate at 0.2a may have fetched origin/<base> minutes ago,
#     or fell back to local <base> on the no_remote / no_fetch paths).
#     Helper does no fetch — just computes behind_count and overlap.
#
#   active-fetch (--fetch-base <name>)
#     Used at fix/add time when the artifact's review-time snapshot may
#     have aged. Helper runs `git fetch origin <base>` with the same
#     30s soft-timeout pattern as freshness-gate.sh, then compares
#     against `origin/<base>`. On no_remote / fetch failure, falls back
#     to local <base> and surfaces the resolution via comparison_ref_used
#     + warnings[] so the orchestrator can be honest in the prompt.
#
# Both modes also require:
#   --reviewed-files @-                      (read newline-separated paths from stdin)
#   --reviewed-files <newline-separated>     (or pass them inline)
#
# Output (stdout): single JSON object.
#
#   {
#     "behind_count":         <int>,
#     "overlap_count":        <int>,
#     "overlap_files":        ["path/a.ts", ..., "…+N more"],
#     "comparison_ref_used":  "<ref>",
#     "warnings":             ["fetch_failed origin main rc=128 err=...", ...]
#   }
#
# `comparison_ref_used` reflects what was actually compared against
# (active-fetch: "origin/<base>" on success, "<base>" on fallback;
# passive: the input ref). Callers log this so trace.md makes the
# resolution explicit.
#
# `overlap_files` is truncated to the first OVERLAP_TRUNCATE paths
# (sorted) plus a "…+N more" sentinel when the actual count exceeds
# the cutoff. The sentinel is element OVERLAP_TRUNCATE+1 (so a
# 25-overlap renders as 10 paths + "…+15 more" as element 11).
#
# Side effects on the working tree:
#   - active-fetch mode: one `git fetch origin <base>` (no ref update,
#     just FETCH_HEAD — same as freshness-gate.sh's initial fetch).
#   - passive mode: pure read.
#
# Exit codes: 0 success; 1 validation error (e.g., comparison_ref does
# not resolve); 64 usage error (mode mutex / missing flags).

set -euo pipefail

# Truncation cutoff for `overlap_files`. Single-source-of-truth knob;
# tune here if it ever needs adjustment. See plan §4.1 / Q3 for the
# rationale (10 keeps full file context for small overlaps where paths
# influence the user's "merge first vs proceed" decision; above the
# cutoff the user is deciding on count alone).
OVERLAP_TRUNCATE=10

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") (--comparison-ref <ref> | --fetch-base <name>) \\
                       --reviewed-files (@- | <newline-separated>)

Preflight check: is HEAD behind <comparison_ref> / origin/<base>, and
which of those behind-commits modified files in this PR's diff?

  --comparison-ref     Passive mode. Caller-resolved ref to compare
                       HEAD against (e.g., main, origin/main). No fetch.
  --fetch-base         Active-fetch mode. Helper runs \`git fetch origin
                       <base>\` with a 30s soft timeout and compares
                       against origin/<base>. Falls back to local <base>
                       on no_remote / fetch failure (resolution surfaces
                       via comparison_ref_used + warnings[]).
  --reviewed-files     Required. Either '@-' (read newline-separated
                       paths from stdin) or a literal newline-separated
                       string of paths.

Modes are mutually exclusive — passing both or neither is exit 64.

Output: single JSON object on stdout with behind_count, overlap_count,
overlap_files[], comparison_ref_used, warnings[].

See plans/branch-behind-base-gate.md and CLAUDE.md "Helper index" for
the orchestrator-side AskUserQuestion flow that consumes this output.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

die_validation() {
    echo "ERROR: $1" >&2
    [[ -n "${2:-}" ]] && echo "Action: $2" >&2
    exit 1
}

COMPARISON_REF=""
FETCH_BASE=""
REVIEWED_FILES_RAW=""
REVIEWED_FILES_FROM_STDIN="0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --comparison-ref)
            [[ $# -ge 2 ]] || die_usage "--comparison-ref requires a value"
            COMPARISON_REF="${2:-}";  shift 2 ;;
        --fetch-base)
            [[ $# -ge 2 ]] || die_usage "--fetch-base requires a value"
            FETCH_BASE="${2:-}";      shift 2 ;;
        --reviewed-files)
            [[ $# -ge 2 ]] || die_usage "--reviewed-files requires a value"
            if [[ "${2:-}" == "@-" ]]; then
                REVIEWED_FILES_FROM_STDIN="1"
            else
                REVIEWED_FILES_RAW="${2:-}"
            fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown arg '$1'" ;;
    esac
done

# Mode mutex: exactly one of --comparison-ref / --fetch-base required.
if [[ -n "$COMPARISON_REF" && -n "$FETCH_BASE" ]]; then
    die_usage "--comparison-ref and --fetch-base are mutually exclusive"
fi
if [[ -z "$COMPARISON_REF" && -z "$FETCH_BASE" ]]; then
    die_usage "one of --comparison-ref or --fetch-base is required"
fi

# --reviewed-files is required in both modes (must be non-empty).
# Phase 0/7/3a callers always build reviewed_files_all from a non-trivial
# diff and pipe via @-, so an empty value is a caller bug, not a valid
# "assert empty staleness envelope" assertion.
if [[ "$REVIEWED_FILES_FROM_STDIN" == "0" && -z "$REVIEWED_FILES_RAW" ]]; then
    die_usage "--reviewed-files is required (use @- for stdin, or pass a newline-separated string)"
fi

if [[ "$REVIEWED_FILES_FROM_STDIN" == "1" ]]; then
    REVIEWED_FILES_RAW="$(cat || true)"
fi

# Sanity-check we're inside a git working tree. Callers (Phase 0/7/3a)
# already validated this; this is belt-and-suspenders.
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    die_validation "not inside a git working tree" \
        "run from within the repo root."
fi

# ---- emission helper ----------------------------------------------------

# Build a jq-safe JSON string array from shell lines (one element per
# non-empty stdin line). Empty stdin → `[]`. Mirrors freshness-gate.sh:181.
lines_to_json_array() {
    jq -Rn '[inputs | select(length>0)]'
}

# Emit the terminal JSON object.
#   $1 behind_count (int)
#   $2 overlap_count (int)
#   $3 newline-separated overlap_files (already truncated + sentinel)
#   $4 comparison_ref_used
#   $5 newline-separated warnings (one per line; empty → [])
emit_terminal() {
    local behind="$1" overlap="$2" overlap_files="$3" compref_used="$4" warnings="$5"
    local overlap_files_json warnings_json
    overlap_files_json=$(printf '%s\n' "$overlap_files" | lines_to_json_array)
    warnings_json=$(printf '%s\n' "$warnings" | lines_to_json_array)
    jq -n \
        --argjson behind "$behind" \
        --argjson overlap "$overlap" \
        --argjson overlap_files "$overlap_files_json" \
        --arg compref_used "$compref_used" \
        --argjson warnings "$warnings_json" \
        '{
            behind_count:        $behind,
            overlap_count:       $overlap,
            overlap_files:       $overlap_files,
            comparison_ref_used: $compref_used,
            warnings:            $warnings
        }'
}

# ---- mode dispatch: resolve comparison_ref_used + collect warnings -----

WARNINGS=""        # newline-separated; empty string → []
COMPARISON_REF_USED=""

append_warning() {
    if [[ -z "$WARNINGS" ]]; then
        WARNINGS="$1"
    else
        WARNINGS="$WARNINGS"$'\n'"$1"
    fi
}

if [[ -n "$FETCH_BASE" ]]; then
    # Active-fetch mode.
    if ! git remote get-url origin >/dev/null 2>&1; then
        # Purely local repo — fall back to local <base>, surface no_remote.
        COMPARISON_REF_USED="$FETCH_BASE"
        append_warning "no_remote"
    else
        # Remote exists. Fetch with 30s soft timeout. GNU `timeout` when
        # available; background+watchdog fallback for macOS without it.
        # Pattern copied from freshness-gate.sh:262-273.
        fetch_err_file=$(mktemp -t adams-bbb-fetch-err.XXXXXX)
        fetch_rc=0
        if command -v timeout >/dev/null 2>&1; then
            timeout 30 git fetch origin "$FETCH_BASE" --quiet 2>"$fetch_err_file" || fetch_rc=$?
        else
            ( git fetch origin "$FETCH_BASE" --quiet 2>"$fetch_err_file" ) &
            fetch_pid=$!
            ( sleep 30 && kill -TERM "$fetch_pid" 2>/dev/null ) &
            watchdog_pid=$!
            wait "$fetch_pid" 2>/dev/null || fetch_rc=$?
            kill -TERM "$watchdog_pid" 2>/dev/null || true
            wait "$watchdog_pid" 2>/dev/null || true
        fi

        if [[ $fetch_rc -ne 0 ]]; then
            err_msg=$(tr '\n' ' ' < "$fetch_err_file" 2>/dev/null || true)
            COMPARISON_REF_USED="$FETCH_BASE"
            append_warning "fetch_failed origin $FETCH_BASE rc=$fetch_rc err=$err_msg"
        else
            COMPARISON_REF_USED="origin/$FETCH_BASE"
        fi
        rm -f "$fetch_err_file"
    fi
else
    # Passive mode.
    COMPARISON_REF_USED="$COMPARISON_REF"
fi

# ---- validate the ref resolves -----------------------------------------

if ! git rev-parse --verify "${COMPARISON_REF_USED}^{commit}" >/dev/null 2>&1; then
    {
        echo "ERROR: comparison ref '$COMPARISON_REF_USED' does not resolve to a commit"
        echo "Context: branch-behind-base.sh needs a ref that git rev-parse can resolve so the behind-count and overlap diff have a valid anchor."
        echo "Valid values: any revspec git understands (branch name, tag, remote-tracking name, SHA)."
        echo "Action: try \`git branch -a\` to list available refs, or re-run with --fetch-base if you expected origin/<base> to exist."
    } >&2
    exit 1
fi

# ---- compute behind_count ----------------------------------------------

behind_count=$(git rev-list --count "HEAD..$COMPARISON_REF_USED" 2>/dev/null || echo 0)

if [[ "$behind_count" -eq 0 ]]; then
    # Short-circuit — no diff computed. Emit zeros + comparison_ref_used + warnings.
    emit_terminal "0" "0" "" "$COMPARISON_REF_USED" "$WARNINGS"
    exit 0
fi

# ---- compute file-set overlap (Bash 3.2-safe) --------------------------

behind_files_tmp=$(mktemp -t adams-bbb-behind.XXXXXX)
reviewed_files_tmp=$(mktemp -t adams-bbb-reviewed.XXXXXX)

# Three-dot `git diff --name-only HEAD...ref` shows files changed
# between merge-base(HEAD, ref) and ref — i.e., what the base side
# added since divergence. This:
#   - excludes branch-only adds (two-dot HEAD..ref would include them
#     and falsely inflate overlap_count),
#   - includes files changed only inside merge commits on the base side
#     (which `git log HEAD..ref --name-only` silently drops by default,
#     because git log skips per-file output for merge commits without
#     -m / --first-parent / -c).
git diff --name-only "HEAD...$COMPARISON_REF_USED" \
    | sort -u > "$behind_files_tmp"
printf '%s\n' "$REVIEWED_FILES_RAW" | sed '/^$/d' | sort -u > "$reviewed_files_tmp"

overlap_full=$(comm -12 "$behind_files_tmp" "$reviewed_files_tmp" || true)
rm -f "$behind_files_tmp" "$reviewed_files_tmp"

if [[ -z "$overlap_full" ]]; then
    overlap_count=0
    overlap_files=""
else
    overlap_count=$(printf '%s\n' "$overlap_full" | wc -l | tr -d ' ')
    if [[ "$overlap_count" -gt "$OVERLAP_TRUNCATE" ]]; then
        # Take first N (already sorted), append "…+(remainder) more"
        # sentinel as element N+1.
        overlap_truncated=$(printf '%s\n' "$overlap_full" | head -n "$OVERLAP_TRUNCATE")
        remainder=$((overlap_count - OVERLAP_TRUNCATE))
        overlap_files="$overlap_truncated"$'\n'"…+$remainder more"
    else
        overlap_files="$overlap_full"
    fi
fi

emit_terminal "$behind_count" "$overlap_count" "$overlap_files" "$COMPARISON_REF_USED" "$WARNINGS"
exit 0
