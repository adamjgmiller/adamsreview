#!/usr/bin/env bash
# codex-poll.sh — Phase 1/4/5 codex-companion job-liveness watchdog.
#
# Wraps `node "$CODEX_COMPANION" status --json` with a two-signal stall
# check + wall-clock ceiling. Single source of truth for codex-poll
# semantics consumed by:
#
#   - fragments/01-codex-detection.md   §1.4   (Phase 1 lens jobs)
#   - fragments/05-codex-validation.md  §4.2.3 (Phase 4a deep validation)
#   - fragments/05-codex-validation.md  §4.3.2 (Phase 4b light chunked-batch)
#   - fragments/06-codex-cross-cutting.md §5.2.2 (Phase 5 cross-cutting)
#
# Required by `/adamsreview:codex-review`. See plans/codex-watchdog.md
# for the bug class this helper defends against (broker reports
# `running` long after the underlying codex turn has died — a desync
# between the broker's in-memory state and its on-disk job store).
#
# The two signals:
#
#   1. logFile mtime age > stall_threshold (default 90s) — the codex
#      child has stopped writing progress.
#   2. `result --json` exits non-zero with stderr matching
#      /No (?:finished )?job found/ — the disk store has no record of
#      the job, even though the broker's in-memory state says `running`.
#
# When BOTH fire → broker_desynced (kill + retry).
# When ONLY (1) fires → stalled_suspect (keep polling; broker's still
# coherent; the job may legitimately be reasoning between tool calls).
#
# Usage:
#   codex-poll.sh --job <jobId> --companion <codex-companion.mjs> \
#                 --stall-threshold-sec <N> \
#                 --wall-clock-ceiling-sec <N>
#
# Stdout: a single JSON object, exactly one of:
#   {"status":"completed", "verdict":"completed", ..., "raw_output":"..."}
#   {"status":"failed",    "verdict":"failed_terminal", ...}
#   {"status":"cancelled", "verdict":"failed_terminal", ...}
#   {"status":"<any>",     "verdict":"wall_clock_exceeded", ...}
#   {"status":"running",   "verdict":"alive", ...}
#   {"status":"running",   "verdict":"stalled_suspect", ...}
#   {"status":"running",   "verdict":"broker_desynced", ...}
#
# Caller branches on `verdict`:
#   alive | stalled_suspect           → keep polling
#   completed                         → consume raw_output, exit loop
#   failed_terminal                   → §3.7 retry / drop
#   broker_desynced | wall_clock_exceeded → cancel + §3.7 retry / drop
#
# Exit codes:
#   0   verdict emitted on stdout (the verdict carries the meaning;
#       we do not use exit codes to encode decisions)
#   5   codex-companion missing or `status --json` itself failed
#  64   usage error

set -u
set -o pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --job <jobId> --companion <codex-companion.mjs> \\
                          --stall-threshold-sec <N> \\
                          --wall-clock-ceiling-sec <N>

Polls codex-companion for one job's state with stall + wall-clock
guards. Emits a single JSON verdict object on stdout. See
plans/codex-watchdog.md for the design.

  --job                       Required. Codex jobId from \`task --background\`.
  --companion                 Required. Absolute path to codex-companion.mjs.
  --stall-threshold-sec       Required. Logfile-mtime age (seconds) above
                              which the helper triggers the desync check.
                              Plan default: 90.
  --wall-clock-ceiling-sec    Required. Elapsed-since-start ceiling
                              (seconds); when exceeded, verdict is
                              wall_clock_exceeded. Per-effort table in
                              plans/codex-watchdog.md.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }
die_dep() {
    echo "ERROR: $1" >&2
    [[ -n "${2:-}" ]] && echo "Action: $2" >&2
    exit 5
}

JOB=""
COMPANION=""
STALL=""
CEIL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --job)
            [[ $# -ge 2 ]] || die_usage "--job requires a value"
            JOB="${2:-}"; shift 2 ;;
        --companion)
            [[ $# -ge 2 ]] || die_usage "--companion requires a value"
            COMPANION="${2:-}"; shift 2 ;;
        --stall-threshold-sec)
            [[ $# -ge 2 ]] || die_usage "--stall-threshold-sec requires a value"
            STALL="${2:-}"; shift 2 ;;
        --wall-clock-ceiling-sec)
            [[ $# -ge 2 ]] || die_usage "--wall-clock-ceiling-sec requires a value"
            CEIL="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$JOB"       ]] || die_usage "--job is required"
[[ -n "$COMPANION" ]] || die_usage "--companion is required"
[[ -n "$STALL"     ]] || die_usage "--stall-threshold-sec is required"
[[ -n "$CEIL"      ]] || die_usage "--wall-clock-ceiling-sec is required"

case "$STALL" in [0-9]*) ;; *) die_usage "--stall-threshold-sec must be a non-negative integer (got '$STALL')" ;; esac
case "$CEIL"  in [0-9]*) ;; *) die_usage "--wall-clock-ceiling-sec must be a non-negative integer (got '$CEIL')" ;; esac

if ! command -v node >/dev/null 2>&1; then
    die_dep "node not found on \$PATH" \
        "install Node.js (codex-companion is a Node script)."
fi
if [[ ! -f "$COMPANION" ]]; then
    die_dep "codex-companion not found at '$COMPANION'" \
        "verify the codex plugin is installed and \$CODEX_COMPANION is set."
fi

# ---- emission helper ----------------------------------------------------

# Emit verdict JSON on stdout.
#   $1 status      "completed" | "failed" | "cancelled" | "running" | "queued"
#   $2 verdict     "alive" | "stalled_suspect" | "broker_desynced"
#                | "wall_clock_exceeded" | "completed" | "failed_terminal"
#   $3 log_file    absolute path or "" → null
#   $4 mtime_age   integer seconds or "" → null
#   $5 elapsed     integer seconds or "" → null
#   $6 (optional)  literal "yes" → also include `raw_output` field, read
#                  as raw stdin (preserves backslashes / quotes / newlines).
emit() {
    local status="$1" verdict="$2" log_file="$3" mtime_age="$4" elapsed="$5"
    local include_raw="${6:-no}"
    if [[ "$include_raw" == "yes" ]]; then
        jq -nR --rawfile raw /dev/stdin \
            --arg status "$status" \
            --arg verdict "$verdict" \
            --arg log_file "$log_file" \
            --arg mtime_age "$mtime_age" \
            --arg elapsed "$elapsed" '
            {
                status: $status,
                verdict: $verdict,
                log_file: (if $log_file == "" then null else $log_file end),
                log_mtime_age_sec: (if $mtime_age == "" then null else ($mtime_age | tonumber) end),
                elapsed_sec: (if $elapsed == "" then null else ($elapsed | tonumber) end),
                raw_output: $raw
            }'
    else
        jq -n \
            --arg status "$status" \
            --arg verdict "$verdict" \
            --arg log_file "$log_file" \
            --arg mtime_age "$mtime_age" \
            --arg elapsed "$elapsed" '
            {
                status: $status,
                verdict: $verdict,
                log_file: (if $log_file == "" then null else $log_file end),
                log_mtime_age_sec: (if $mtime_age == "" then null else ($mtime_age | tonumber) end),
                elapsed_sec: (if $elapsed == "" then null else ($elapsed | tonumber) end)
            }'
    fi
}

# Compute logFile mtime age in seconds. Empty result when the file is
# missing or unstattable. Caller chooses what default to apply.
#   $1 logFile path
#   $2 now-epoch
compute_mtime_age() {
    local lf="$1" now_epoch="$2"
    if [[ -n "$lf" && -e "$lf" ]]; then
        # GNU stat (-c %Y) and BSD stat (-f %m) diverge — try both.
        local mt
        mt=$(stat -c %Y "$lf" 2>/dev/null || stat -f %m "$lf" 2>/dev/null || echo "")
        if [[ -n "$mt" ]]; then
            echo "$(( now_epoch - mt ))"
            return
        fi
    fi
    echo ""
}

# ---- 1. status --json ---------------------------------------------------

status_err=$(mktemp -t adams-codex-poll.XXXXXX)
status_out=$(node "$COMPANION" status "$JOB" --json 2>"$status_err") || {
    rc=$?
    err=$(tr '\n' ' ' <"$status_err" 2>/dev/null || true)
    rm -f "$status_err"
    # Pruned/unknown job — the disk store has no record of this jobId.
    # `lib/job-control.mjs` `buildSingleJobSnapshot` throws
    # `No job found for "<id>". Run /codex:status...` in this case.
    # Convert to a graceful broker_desynced verdict (mirrors what we do
    # for `result --json` at the stall-confirm path below, lines ~306)
    # so the caller routes the single finding/chunk to §4.2.4
    # sentinel-uncertain instead of aborting the whole batch under
    # `set -euo pipefail`. Other status failures (broker unreachable,
    # node missing, malformed args) still die_dep — they are real
    # infrastructure problems, not graceful per-unit fallouts.
    if printf '%s' "$err" | grep -qE 'No job found'; then
        emit "unknown" "broker_desynced" "" "" ""
        exit 0
    fi
    die_dep "codex-companion 'status' failed (rc=$rc): $err" \
        "the codex broker may be unreachable. Run \`node \"\$CODEX_COMPANION\" status\` manually to inspect."
}
rm -f "$status_err"

job_status=$( printf '%s' "$status_out" | jq -r '.job.status // empty')
log_file=$(   printf '%s' "$status_out" | jq -r '.job.logFile // empty')
started_at=$( printf '%s' "$status_out" | jq -r '.job.startedAt // .job.createdAt // empty')

if [[ -z "$job_status" ]]; then
    die_dep "codex-companion 'status --json' did not include .job.status" \
        "verify codex-companion exposes the documented snapshot shape."
fi

# Compute elapsed_sec from startedAt (best-effort).
now=$(date +%s)
started_epoch=""
if [[ -n "$started_at" ]]; then
    # GNU date first, then python3 fallback for BSD/macOS.
    started_epoch=$(date -d "$started_at" +%s 2>/dev/null || true)
    if [[ -z "$started_epoch" ]]; then
        started_epoch=$(python3 - "$started_at" <<'PY' 2>/dev/null || true
import sys, datetime
try:
    s = sys.argv[1].replace("Z", "+00:00")
    print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception:
    pass
PY
)
    fi
fi
elapsed_sec=""
if [[ -n "$started_epoch" ]]; then
    elapsed_sec=$(( now - started_epoch ))
fi

# ---- 2. terminal short-circuit ------------------------------------------

case "$job_status" in
    completed)
        # Pluck raw_output via the same chain the fragments use today
        # (the disk-persisted store is the source of truth even when
        # the broker reports completed).
        result_err=$(mktemp -t adams-codex-poll-result.XXXXXX)
        result_out=$(node "$COMPANION" result "$JOB" --json 2>"$result_err" || true)
        rm -f "$result_err"
        raw=$(printf '%s' "$result_out" | jq -r '
            .storedJob.result.rawOutput // .storedJob.payload.rawOutput // .storedJob.rawOutput // ""
        ' 2>/dev/null || printf '%s' "")
        mtime_age=$(compute_mtime_age "$log_file" "$now")
        printf '%s' "$raw" | emit "completed" "completed" "$log_file" "$mtime_age" "$elapsed_sec" "yes"
        exit 0
        ;;
    failed|cancelled)
        mtime_age=$(compute_mtime_age "$log_file" "$now")
        emit "$job_status" "failed_terminal" "$log_file" "$mtime_age" "$elapsed_sec"
        exit 0
        ;;
esac

# Non-terminal (queued | running | unknown): liveness checks.

# ---- 3. wall-clock ceiling ----------------------------------------------

if [[ -n "$elapsed_sec" && "$elapsed_sec" -gt "$CEIL" ]]; then
    mtime_age=$(compute_mtime_age "$log_file" "$now")
    emit "$job_status" "wall_clock_exceeded" "$log_file" "$mtime_age" "$elapsed_sec"
    exit 0
fi

# ---- 4. logfile mtime age ------------------------------------------------

# Default to 999 when logFile is missing or unstattable — the job has
# never written progress (e.g., codex child died at launch). That's
# already a broken state; treat as definitively past the stall threshold.
mtime_age=$(compute_mtime_age "$log_file" "$now")
[[ -z "$mtime_age" ]] && mtime_age=999

if [[ "$mtime_age" -le "$STALL" ]]; then
    emit "$job_status" "alive" "$log_file" "$mtime_age" "$elapsed_sec"
    exit 0
fi

# ---- 5. stall suspected — confirm via result --json ---------------------
#
# `result --json` reads the disk-persisted job file
# (lib/job-control.mjs `readStoredJob` via `resolveResultJob`). When
# the broker's in-memory state says `running` but the disk store has
# no record of the job, the broker's two stores have desynced — that
# is the confirmed-dead signal.
#
# Match both the "No job found" (status read path) and the
# "No finished job found" (resolveResultJob path) error messages —
# either indicates the disk store does not know about this job.
#
# A non-zero exit with a "still running" stderr (resolveResultJob's
# active-job path) is NOT a desync — it just means broker and disk
# agree the job is alive. Stay in stalled_suspect for those.

result_err=$(mktemp -t adams-codex-poll-result.XXXXXX)
result_rc=0
node "$COMPANION" result "$JOB" --json >/dev/null 2>"$result_err" || result_rc=$?
result_stderr=$(cat "$result_err" 2>/dev/null || true)
rm -f "$result_err"

if [[ "$result_rc" -ne 0 ]] \
   && printf '%s' "$result_stderr" | grep -qE 'No (finished )?job found'; then
    emit "$job_status" "broker_desynced" "$log_file" "$mtime_age" "$elapsed_sec"
    exit 0
fi

emit "$job_status" "stalled_suspect" "$log_file" "$mtime_age" "$elapsed_sec"
exit 0
