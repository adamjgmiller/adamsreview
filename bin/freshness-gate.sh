#!/usr/bin/env bash
# freshness-gate.sh — Phase 0.2a base-branch freshness reconciliation
# (DESIGN §13.10). Extracts the ~80-line inline bash block from
# fragments/00-preflight.md step 0.2a.
#
# The `AskUserQuestion` dispatch stays orchestrator-side: this helper
# does everything *up to* the point where a behind-count case would
# need user input, emits `base_freshness: "pending_user_gate"` in that
# case, and exits 0 so the orchestrator can branch and re-invoke with
# `--after-choice <a|b|c>` to apply the user's selection.
#
# Usage (first invocation — detect + fetch + compute behind_count):
#   freshness-gate.sh --base-branch <name> --head-branch <name>
#
# Usage (re-invocation with user's choice — applies side-effect):
#   freshness-gate.sh --base-branch <name> --head-branch <name> \
#                     --after-choice <a|b|c>
#
# `--after-choice d` (abort) is orchestrator-level — the helper is
# never invoked for the abort case. Choice `a` may fail with non-FF
# divergence, in which case the helper re-emits pending (with
# `ff_available: false`) so the orchestrator re-asks with only b/c/d.
#
# Output (stdout): a single JSON object. Terminal states have a
# terminal `base_freshness` and `preflight_warnings[]` to flush to
# trace.md. Pending states require orchestrator action.
#
#   {
#     "comparison_ref":       "<ref>" | null,
#     "base_freshness":       "fresh" | "fast_forwarded"
#                           | "used_remote_ref" | "proceeded_stale"
#                           | "no_remote" | "no_fetch"
#                           | "pending_user_gate",
#     "remote_sha":           "<sha>" | null,
#     "behind_count":         <int>   | null,
#     "preflight_warnings":   [ "<string>", ... ],
#     "ff_available":         true | false     (only on pending_user_gate)
#   }
#
# Side effects on the working tree:
#   - Initial invocation runs `git fetch origin <base_branch>` (no ref
#     update — just `FETCH_HEAD`).
#   - `--after-choice a` fast-forwards the local base branch. When HEAD
#     is on a different branch, it runs `git fetch origin <base>:<base>`.
#     When HEAD is already on <base-branch> (git refuses to update the
#     currently-checked-out ref via a fetch refspec), it falls back to
#     `git merge --ff-only origin/<base-branch>` instead — `origin/<base>`
#     was already populated by the initial fetch earlier in the helper.
#     Git refuses non-FF updates, which the helper catches and reports
#     as pending_user_gate with ff_available=false.
#   - `--after-choice b` and `--after-choice c` have no working-tree
#     side effects (they only change the emitted `comparison_ref` and
#     `base_freshness`).
#
# Exit codes: 0 success; 1 validation error (e.g., base branch does not
# exist); 64 usage error.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --base-branch <name> --head-branch <name> [--after-choice <a|b|c>]

Reconciles the local base branch against origin/<base-branch> and emits
a JSON object with \`comparison_ref\`, \`base_freshness\`, \`remote_sha\`,
\`behind_count\`, and \`preflight_warnings\`.

  --base-branch    Required. The base branch name (e.g., main).
  --head-branch    Required. The head branch name. Reserved for future
                   per-branch logic; currently unused but accepted so
                   the call site documents its intent.
  --after-choice   Optional. When re-invoked after AskUserQuestion:
                   a = fast-forward local <base-branch>
                   b = compare against origin/<base-branch>
                   c = proceed with stale local <base-branch>

See fragments/00-preflight.md step 0.2a for the orchestrator-side
AskUserQuestion flow and the prompt text shown to the user.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

die_validation() {
    echo "ERROR: $1" >&2
    [[ -n "${2:-}" ]] && echo "Action: $2" >&2
    exit 1
}

BASE_BRANCH=""
HEAD_BRANCH=""
AFTER_CHOICE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-branch)
            [[ $# -ge 2 ]] || die_usage "--base-branch requires a value"
            BASE_BRANCH="${2:-}";  shift 2 ;;
        --head-branch)
            [[ $# -ge 2 ]] || die_usage "--head-branch requires a value"
            HEAD_BRANCH="${2:-}";  shift 2 ;;
        --after-choice)
            [[ $# -ge 2 ]] || die_usage "--after-choice requires a value"
            AFTER_CHOICE="${2:-}"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$BASE_BRANCH" ]] || die_usage "--base-branch is required"
[[ -n "$HEAD_BRANCH" ]] || die_usage "--head-branch is required"
case "$AFTER_CHOICE" in
    ""|a|b|c) ;;
    *) die_usage "unknown --after-choice '$AFTER_CHOICE' (expected a|b|c)" ;;
esac

# Confirm we're inside a git working tree. Callers are Phase 0.2 (which
# already called `git rev-parse --show-toplevel`), so this is a belt-
# and-suspenders check, not the primary gate.
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    die_validation "not inside a git working tree" \
        "run from within the repo root, or call \`git init\` first."
fi

# Confirm the base branch exists locally — later rev-parse /
# rev-list calls assume it does. Mirrors step 0.2's third fallback
# (which stops and asks the user if no base resolves).
if ! git show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then
    die_validation "base branch '$BASE_BRANCH' does not exist locally" \
        "verify step 0.2 resolved base_branch to an existing local ref."
fi

# ---- emission helpers ---------------------------------------------------

# Emit the terminal JSON object. Args (positional) in order:
#   1  base_freshness
#   2  comparison_ref (or empty string → null)
#   3  remote_sha     (or empty string → null)
#   4  behind_count   (or empty string → null)
#   5  warnings_json_array_literal (e.g., '[]' or '["fetch_failed ..."]')
emit_terminal() {
    local freshness="$1" compref="$2" rsha="$3" bhc="$4" warnings="$5"
    jq -n \
        --arg freshness "$freshness" \
        --arg compref "$compref" \
        --arg rsha "$rsha" \
        --arg bhc "$bhc" \
        --argjson warnings "$warnings" \
        '{
            comparison_ref:     (if $compref == "" then null else $compref end),
            base_freshness:     $freshness,
            remote_sha:         (if $rsha == ""    then null else $rsha end),
            behind_count:       (if $bhc == ""     then null else ($bhc | tonumber) end),
            preflight_warnings: $warnings
        }'
}

# Emit a pending JSON object (behind_count > 0 path). `ff_available`
# signals to the orchestrator whether to offer option (a) in its
# AskUserQuestion. Set false after a non-FF (a)-retry failure.
emit_pending() {
    local rsha="$1" bhc="$2" warnings="$3" ff_available="$4"
    jq -n \
        --arg rsha "$rsha" \
        --arg bhc "$bhc" \
        --argjson warnings "$warnings" \
        --argjson ff_available "$ff_available" \
        '{
            comparison_ref:     null,
            base_freshness:     "pending_user_gate",
            remote_sha:         (if $rsha == "" then null else $rsha end),
            behind_count:       (if $bhc == ""  then null else ($bhc | tonumber) end),
            preflight_warnings: $warnings,
            ff_available:       $ff_available
        }'
}

# Build a jq-safe JSON string array from shell lines (one element per
# non-empty stdin line). Empty stdin → `[]`.
lines_to_json_array() {
    jq -Rn '[inputs | select(length>0)]'
}

# --- after-choice branches (short-circuit: side-effect + emit) -----------

if [[ "$AFTER_CHOICE" == "b" ]]; then
    # Compare against origin/<base-branch>; no local mutation.
    remote_sha=$(git rev-parse "origin/$BASE_BRANCH" 2>/dev/null || true)
    behind_count=$(git rev-list --count "$BASE_BRANCH..origin/$BASE_BRANCH" 2>/dev/null || echo 0)
    emit_terminal "used_remote_ref" "origin/$BASE_BRANCH" "$remote_sha" "$behind_count" '[]'
    exit 0
fi

if [[ "$AFTER_CHOICE" == "c" ]]; then
    # Proceed with stale local base; buffer warning for trace.md.
    remote_sha=$(git rev-parse "origin/$BASE_BRANCH" 2>/dev/null || true)
    behind_count=$(git rev-list --count "$BASE_BRANCH..origin/$BASE_BRANCH" 2>/dev/null || echo 0)
    warnings_json=$(printf '%s\n' "proceeded_stale base=$BASE_BRANCH behind_count=$behind_count" | lines_to_json_array)
    emit_terminal "proceeded_stale" "$BASE_BRANCH" "$remote_sha" "$behind_count" "$warnings_json"
    exit 0
fi

if [[ "$AFTER_CHOICE" == "a" ]]; then
    # Fast-forward local base; git refuses non-FF updates → re-emit
    # pending with ff_available=false so orchestrator re-asks with b/c/d.
    #
    # HEAD-on-base fallback: if HEAD is currently on $BASE_BRANCH, git
    # refuses to update the checked-out ref via `fetch origin base:base`,
    # so use `git merge --ff-only origin/$BASE_BRANCH` — origin/$BASE_BRANCH
    # is already populated by the initial fetch earlier in the helper.
    current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
    if [[ "$current_branch" == "$BASE_BRANCH" ]]; then
        ff_err_file=$(mktemp -t adams-ff-err.XXXXXX)
        ff_rc=0
        git merge --ff-only "origin/$BASE_BRANCH" --quiet 2>"$ff_err_file" || ff_rc=$?
        if [[ $ff_rc -eq 0 ]]; then
            remote_sha=$(git rev-parse "origin/$BASE_BRANCH" 2>/dev/null || true)
            emit_terminal "fast_forwarded" "$BASE_BRANCH" "$remote_sha" "0" '[]'
            rm -f "$ff_err_file"
            exit 0
        fi
        err_msg=$(tr '\n' ' ' < "$ff_err_file" 2>/dev/null || true)
        rm -f "$ff_err_file"
        remote_sha=$(git rev-parse "origin/$BASE_BRANCH" 2>/dev/null || true)
        behind_count=$(git rev-list --count "$BASE_BRANCH..origin/$BASE_BRANCH" 2>/dev/null || echo 0)
        warnings_json=$(printf '%s\n' "fast_forward_failed base=$BASE_BRANCH rc=$ff_rc err=$err_msg" | lines_to_json_array)
        emit_pending "$remote_sha" "$behind_count" "$warnings_json" "false"
        exit 0
    fi
    ff_err_file=$(mktemp -t adams-ff-err.XXXXXX)
    ff_rc=0
    git fetch origin "$BASE_BRANCH:$BASE_BRANCH" --quiet 2>"$ff_err_file" || ff_rc=$?
    if [[ $ff_rc -eq 0 ]]; then
        remote_sha=$(git rev-parse "origin/$BASE_BRANCH" 2>/dev/null || true)
        emit_terminal "fast_forwarded" "$BASE_BRANCH" "$remote_sha" "0" '[]'
        rm -f "$ff_err_file"
        exit 0
    fi
    # Non-FF divergence (or other fetch failure) on the user-requested
    # fast-forward — buffer the stderr, re-emit pending with ff_available=false.
    err_msg=$(tr '\n' ' ' < "$ff_err_file" 2>/dev/null || true)
    rm -f "$ff_err_file"
    remote_sha=$(git rev-parse "origin/$BASE_BRANCH" 2>/dev/null || true)
    behind_count=$(git rev-list --count "$BASE_BRANCH..origin/$BASE_BRANCH" 2>/dev/null || echo 0)
    warnings_json=$(printf '%s\n' "fast_forward_failed base=$BASE_BRANCH rc=$ff_rc err=$err_msg" | lines_to_json_array)
    emit_pending "$remote_sha" "$behind_count" "$warnings_json" "false"
    exit 0
fi

# --- initial invocation (no --after-choice) ------------------------------

# Step 1. Detect whether a remote exists, and fetch if it does.
if ! git remote get-url origin >/dev/null 2>&1; then
    # Purely local repo — nothing to reconcile.
    emit_terminal "no_remote" "$BASE_BRANCH" "" "" '[]'
    exit 0
fi

# Remote exists. Fetch with a 30s soft timeout. GNU `timeout` when
# available; a background+watchdog pattern on macOS where it isn't.
fetch_err_file=$(mktemp -t adams-fetch-err.XXXXXX)
fetch_rc=0
if command -v timeout >/dev/null 2>&1; then
    timeout 30 git fetch origin "$BASE_BRANCH" --quiet 2>"$fetch_err_file" || fetch_rc=$?
else
    ( git fetch origin "$BASE_BRANCH" --quiet 2>"$fetch_err_file" ) &
    fetch_pid=$!
    ( sleep 30 && kill -TERM "$fetch_pid" 2>/dev/null ) &
    watchdog_pid=$!
    wait "$fetch_pid" 2>/dev/null || fetch_rc=$?
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
fi

if [[ $fetch_rc -ne 0 ]]; then
    # Fetch failed (network, no upstream for this branch, timeout).
    # Do NOT prompt; do NOT abort — offline/airgapped runs must proceed.
    err_msg=$(tr '\n' ' ' < "$fetch_err_file" 2>/dev/null || true)
    rm -f "$fetch_err_file"
    warnings_json=$(printf '%s\n' "fetch_failed origin $BASE_BRANCH rc=$fetch_rc err=$err_msg" | lines_to_json_array)
    emit_terminal "no_fetch" "$BASE_BRANCH" "" "" "$warnings_json"
    exit 0
fi
rm -f "$fetch_err_file"

# Step 2. Compute behind_count and route.
remote_sha=$(git rev-parse "origin/$BASE_BRANCH")
behind_count=$(git rev-list --count "$BASE_BRANCH..origin/$BASE_BRANCH" 2>/dev/null || echo 0)

if [[ "$behind_count" -eq 0 ]]; then
    emit_terminal "fresh" "$BASE_BRANCH" "$remote_sha" "0" '[]'
    exit 0
fi

# Step 3. User-gate case: orchestrator takes over. First pending → (a)
# is still on the table, so `ff_available: true`.
emit_pending "$remote_sha" "$behind_count" '[]' "true"
exit 0
