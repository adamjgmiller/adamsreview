# Plan: codex-companion poll-loop watchdog

**Status:** drafted 2026-05-03; awaiting approval. Branch: `codex-review` (this worktree).
**Pattern:** one new helper (`bin/codex-poll.sh`) + four fragment edits replacing raw `status --json` polls + one new smoke assertion (`CR-13`) + manual reproducer test plan. No schema changes; no new commands.

---

## Context

`/adamsreview:codex-review` polls codex-companion for job state at four sites:

- `fragments/01-codex-detection.md` §1.4 — Phase 1 lens-job poll loop (7 jobs)
- `fragments/05-codex-validation.md` §4.2.3 — Phase 4a deep-validation poll (one per finding, 10–30 typical)
- `fragments/05-codex-validation.md` §4.3.2 — Phase 4b light-lane chunk poll (1–N chunks)
- `fragments/06-codex-cross-cutting.md` §5.2.2 — Phase 5 cross-cutting poll (one job)

Every site reads `node "$CODEX_COMPANION" status <jobId> --json | jq -r '.job.status'` and treats anything not in `{completed, failed, cancelled}` as "still working, keep polling." This trusts the broker's `running` status as a liveness signal. **It isn't.**

### Observed failure (2026-05-03 01:55 UTC, beta-briefing/onboard-page)

A real `/adamsreview:codex-review --effort high` run with all 7 lenses launched at 01:54:47–49 went silent within 30 seconds. Diagnostic findings preserved here so future-me doesn't re-investigate:

- All 7 lenses streamed an "Assistant message" + ran 1–4 git diff commands successfully (01:54:58–01:55:15), then **all 7 went silent within a 7-second window**. The synchronized-failure shape rules out 7 independent failures and points to a single upstream event correlated-killing all in-flight streams.
- Each lens's per-job log file (`~/.claude/plugins/data/codex-openai-codex/state/<cwd-slug>/jobs/<job-id>.log`) had its last write at 01:55:08–15 and never wrote again. **mtime stops; status keeps lying.**
- 26 minutes later, user cancelled. codex-companion attempted `interruptAppServerTurn` for each job; all 7 returned `"thread not found: <thread-id>"` (or `"no active turn to interrupt"` for L1). **The codex CLI's *own* internal app-server had idle-GC'd the threads** — the failure is two layers down from the codex-companion broker.
- Codex CLI processes (`node codex app-server` PID 2015414, `codex app-server` PID 2015425) were **still alive 80 minutes later** with ~2 minutes accumulated CPU each — wedged on a network wait, not crashed. Killed manually post-investigation.
- A single fresh codex job at `effort=high` from a different cwd (this worktree) at 03:13 UTC completed in 10s. **A 7-parallel-job test at the same effort completed in 30s, all clean.** The bug is transient — best-fit hypothesis is an OpenAI-backend stream stall correlated across 7 simultaneous streams. Not reproducible on demand.
- Codex CLI has no client-side stream-stall detection; codex-companion's broker has no SIGCHLD handler on detached task-workers (`scripts/codex-companion.mjs:641-651` spawns with `detached: true; unref()` and never attaches an exit listener). Root-cause fixes both live upstream.

### What this plan fixes (and what it doesn't)

This plan does **not** fix the upstream codex CLI bug (silent stream stall). That requires changes in `openai/codex` that we don't control. We're skipping the upstream issue per user decision.

This plan **does** convert "infinite hang on every transient upstream hiccup" into "stall detected → cancel → retry → escalate." Defense in depth at the consumer.

---

## Goal

When a codex job stalls (broker reports `running` but the underlying turn is dead), the consumer detects it within ~90 seconds, cancels the job cleanly, and routes through the existing §3.7 retry-with-orchestrator-judgment policy as if codex had returned a hard `failed` status. After three failed attempts, the same `AskUserQuestion` escalation fires that already exists today.

**Done when:**

1. New helper `bin/codex-poll.sh` wraps the current `status --json | jq` line plus liveness checks and emits a single JSON verdict per call.
2. The four poll sites (above) replace their raw `node "$CODEX_COMPANION" status` line with `codex-poll.sh` and branch on the verdict.
3. Smoke assertion `CR-13` requires every poll site to invoke the helper rather than raw `status --json`. Mirrors CR-9/10/11 discipline (regression guard for the bug class found via real failure).
4. Manual reproducer documented in this plan: kill the codex children mid-poll on a real run; the watchdog should detect and recover.
5. Plugin version bumped (`0.3.0 → 0.3.1`) per CLAUDE.md release discipline.
6. CLAUDE.md helper index gains the new helper. Pipeline-shape diagram for `/adamsreview:codex-review` annotates the watchdog (one-line note in §1.4 / §4.2.3 / §4.3.2 / §5.2.2).

---

## Non-goals / explicitly deferred

- **No upstream codex CLI fix.** Filing the issue against `openai/codex` was considered and skipped per user decision. We may revisit if the bug recurs at a high rate; the watchdog buys us time.
- **No new artifact schema fields.** Watchdog events log to `trace.md` (`phase_<N>_codex_watchdog_*`) under existing conventions. Stall counts roll into existing summary lines.
- **No "fallback to Claude" on Codex failure.** That's already explicitly out of scope for `/adamsreview:codex-review` (`commands/codex-review.md` §"What this command does NOT do"). Watchdog feeds into the existing retry-or-drop policy that ends in `AskUserQuestion`, same as today.
- **No retry-at-lower-effort on stall.** Considered and rejected: the failure isn't tied to effort level; it's a network/backend stall any effort would suffer. Same retry policy at the same effort.
- **No retroactive watchdog for `/adamsreview:review --ensemble`'s Codex CLI invocation.** That path runs Codex as a one-shot subprocess via the ensemble adapter (`fragments/02-ensemble-adapter.md` §1.5.2), not via the polling primitive — different failure surface, different recovery path. Out of scope.
- **No watchdog on Sonnet shape-fixers.** Those are `Agent` calls, not codex-companion polls — covered by Claude Code's own per-tool-use timeouts.

---

## Key design decisions

### Two-signal liveness check, not one

A naive watchdog could fire on `log_mtime_age > 90s` alone. That over-fires: a high-effort codex job CAN legitimately go quiet for 60–120 seconds while reasoning between tool calls. We need a confirmation signal before declaring a stall fatal.

Confirmation: call `node "$CODEX_COMPANION" result <jobId> --json` early. The companion exits 275 with `{error: "No job found"}` when the result store is empty. Per the code-review investigation (`scripts/lib/job-control.mjs:256-280`), `result` reads the disk-persisted job file via `readStoredJob(workspaceRoot, job.id)`, while `status` reads in-memory broker state from `state.json`. **They use different stores.** When the broker reports `running` AND `result` reports "No job found" simultaneously, the broker's two stores disagree — that's the desync signature. Combine with stale `logFile` mtime → confirmed dead.

If only one signal fires, treat as suspect (keep polling). If both fire, treat as dead.

### Hard wall-clock ceiling as backstop

Even with the two-signal check, a malicious/buggy codex run could keep writing log lines while making zero forward progress. A hard wall-clock ceiling per-effort keeps wall-clock predictable:

| effort | ceiling |
|---|---|
| `low` | 5 min |
| `medium` | 8 min |
| `high` | 15 min |
| `xhigh` | 25 min |

These are 3–5x the expected p95 time per job at each effort, leaving slack for legitimate slow jobs. Caller passes the ceiling; the helper enforces it.

### Stall threshold of 90 seconds

Calibration: in the failed onboard-page run, the longest gap between log writes during *normal* operation was ~7 seconds (between completing one git diff and issuing the next). 90s is >10x that ceiling — well clear of normal jitter. Tunable via helper flag if real-world data argues for a different value.

### One shared helper, four call sites

Could inline the watchdog logic at each of the four poll sites. Reasons not to:

- Same logic in four places is exactly the bug-class the existing helpers (`origin-crosscheck.sh`, `freshness-gate.sh`, `comment-freshness.sh`) prevent — single source of truth for tricky semantics.
- Future tunability (stall threshold, ceiling values) lives in one place.
- Smoke `CR-13` becomes a one-grep regression guard ("every poll site invokes the helper").

Helper location: `bin/codex-poll.sh`. Bash, one shebang, follows operational rule 1 (Bash-3.2-portable) and rule 4 (error-as-prompt).

### Output shape

Helper emits one JSON object per call, no stderr noise on the happy path:

```json
{
  "status": "running" | "completed" | "failed" | "cancelled",
  "verdict": "alive" | "stalled_suspect" | "broker_desynced" | "wall_clock_exceeded" | "completed" | "failed_terminal",
  "log_file": "/abs/path/.log",
  "log_mtime_age_sec": 12.4,
  "elapsed_sec": 45,
  "raw_output": "..."   // present only when verdict == "completed"; pluck path same as today
}
```

Caller branches on `verdict`:

- `alive` / `stalled_suspect` → keep polling next iteration
- `completed` → consume `raw_output`, exit poll loop
- `broker_desynced` / `wall_clock_exceeded` / `failed_terminal` → call `cancel`, route to existing §3.7 retry policy

---

## Implementation steps

### Step 1 — Build `bin/codex-poll.sh`

Inputs (all required):
- `--job <jobId>`
- `--companion <path-to-codex-companion.mjs>`
- `--stall-threshold-sec <N>` (default 90)
- `--wall-clock-ceiling-sec <N>` (no default; caller must pass)

Algorithm:

1. Call `node "$CODEX_COMPANION" status "$jobId" --json` → parse `.job.status`, `.job.logFile`, `.job.startedAt` (or `.job.createdAt` if startedAt missing — happens for queued jobs).
2. If status ∈ {`completed`, `failed`, `cancelled`}: short-circuit. For `completed`, additionally call `result --json` and pluck `.storedJob.result.rawOutput // .storedJob.payload.rawOutput // .storedJob.rawOutput // ""`. Emit verdict accordingly.
3. Compute `elapsed_sec = now - startedAt`.
4. If `elapsed_sec > wall_clock_ceiling`: emit `verdict: wall_clock_exceeded`. Done.
5. Compute `log_mtime_age = now - stat(logFile).mtime`. If logFile missing, treat as `999` (job never started writing — already broken).
6. If `log_mtime_age <= stall_threshold`: emit `verdict: alive`. Done.
7. Stall suspected. Call `result --json` once. If exit code 275 OR error message matches `/No (?:finished )?job found/`: emit `verdict: broker_desynced`. Otherwise: emit `verdict: stalled_suspect` (don't kill yet — the result call confirms the broker is sane, the job is just slow).

Errors:
- Missing `--job` / `--companion` / `--wall-clock-ceiling-sec`: error-as-prompt with usage. Exit 64.
- `node "$CODEX_COMPANION" status` exit non-zero: error-as-prompt with stderr passthrough. Exit 5 (missing dep) — same code we use for codex-companion absence.
- All other paths: exit 0 (the verdict carries the meaning; non-zero exits are reserved for "I couldn't decide").

### Step 2 — Replace the four poll sites

Each site changes from (today, `01-codex-detection.md` §1.4):

```bash
status=$(node "$CODEX_COMPANION" status "$job_id" --json | jq -r '.job.status')
if [[ "$status" == "completed" || "$status" == "failed" || "$status" == "cancelled" ]]; then
  # terminal; pluck output if completed
  ...
fi
```

To:

```bash
poll=$(codex-poll.sh --job "$job_id" --companion "$CODEX_COMPANION" \
       --stall-threshold-sec 90 --wall-clock-ceiling-sec "$ceiling")
verdict=$(printf '%s' "$poll" | jq -r '.verdict')
case "$verdict" in
  alive|stalled_suspect)
    continue ;;  # next poll iteration
  completed)
    raw_output=$(printf '%s' "$poll" | jq -r '.raw_output')
    break ;;
  broker_desynced|wall_clock_exceeded|failed_terminal)
    log-phase.sh ... watchdog event
    node "$CODEX_COMPANION" cancel "$job_id" >/dev/null 2>&1 || true
    # route to existing §3.7 retry-with-judgment
    ... ;;
esac
```

Per-site `$ceiling` values:
- `01-codex-detection.md` §1.4: 15 min for `effort=high`, 25 min for `effort=xhigh` (lens job — full reasoning pass on a diff)
- `05-codex-validation.md` §4.2.3: same as detection (deep validation per finding — same kind of reasoning depth)
- `05-codex-validation.md` §4.3.2: 10 min for `effort=high`, 18 min for `effort=xhigh` (light-lane chunked-batch — ≤25 candidates per chunk, simpler reasoning)
- `06-codex-cross-cutting.md` §5.2.2: 8 min for `effort=high`, 12 min for `effort=xhigh` (one pass over already-validated findings — short reasoning)

The §3.7 retry path stays unchanged. Watchdog's contribution is creating a terminal state from a hung one; the existing retry-or-drop logic takes it from there.

### Step 3 — `commands/codex-review.md` `allowed-tools` grant

Add `Bash(codex-poll.sh:*)` to the `allowed-tools` line. Other commands (`/adamsreview:review`, `/adamsreview:fix`, etc.) don't need this grant — codex-poll.sh is codex-review-specific.

### Step 4 — Smoke regression guard CR-13

Mirror CR-9/10/11 pattern. Sit just before the final summary in `test/smoke.sh`:

- Assert every line matching `node[^']*"\$CODEX_COMPANION"[[:space:]]+status` outside the helper itself appears inside a `codex-poll.sh` invocation context.
- Or, simpler: assert `codex-poll.sh` is invoked at least once in each of the four codex fragments, and that no fragment file outside `bin/` calls `node "$CODEX_COMPANION" status` directly. The simpler form is what I'd ship — false-positive risk on the regex form.

CR-13 also asserts the helper file exists and is executable.

Validate via revert/restore: remove one fragment's `codex-poll.sh` invocation → smoke fails CR-13 → restore → passes.

### Step 5 — Plugin version bump

`.claude-plugin/plugin.json`: `0.3.0 → 0.3.1`. Patch bump (bug-class fix per CLAUDE.md release discipline). Same PR.

### Step 6 — CLAUDE.md updates

- Helper index: add `codex-poll.sh` row (Bash, "Phase 1 / 4 / 5 codex-job liveness watchdog. Two-signal stall check + wall-clock ceiling + cancel-and-route on detected dead state. Required by `/adamsreview:codex-review`.")
- Pipeline shape diagram for `/adamsreview:codex-review`: add a one-line annotation under each watchdog'd phase ("watchdog: stall→cancel→retry per §3.7"). Don't redraw the diagram.
- Operational rules: no new rules. Existing rules 4 (error-as-prompt) and 8 (atomic writes — N/A here, helper only reads) cover the discipline.

---

## Smoke + manual test plan

**Smoke (`test/smoke.sh`):**

- CR-13a: `bin/codex-poll.sh` exists, is executable, has `#!/usr/bin/env bash` shebang.
- CR-13b: each of the four fragments invokes `codex-poll.sh` at least once.
- CR-13c: no fragment outside `bin/` calls `node "$CODEX_COMPANION" status` directly anymore.

**Manual reproducer:**

The original failure isn't reproducible on demand (transient backend issue). Manufacture one instead — kill the codex children mid-poll to simulate the "broker says running, codex is dead" state:

1. Run `/adamsreview:codex-review --effort low` on a small PR (low effort ≈ short jobs, fast iteration).
2. While Phase 1 is dispatching, in another shell: `pkill -9 -f 'codex app-server'` to kill the codex backend.
3. The poll loop should see `log_mtime_age > 90s` (no more writes) AND `result --json` returning "No job found" → emit `broker_desynced` → cancel + retry.
4. After 3 retries (all fail because codex backend is dead), `AskUserQuestion` fires with the existing escalation prompt.
5. User picks "Continue with degraded coverage" or "Abort"; trace.md gets clean watchdog event entries.

Also test the wall-clock ceiling path: set a `--wall-clock-ceiling-sec 30` override on a real job that takes 60s, verify the watchdog fires on time even when log writes are progressing.

---

## Risks and mitigations

- **Stall threshold too aggressive** — false-positive watchdog kills on legitimately slow jobs. Mitigation: 90s is >10x normal-jitter ceiling per the diagnostic data; tune via flag if real runs argue otherwise. Track via `phase_<N>_codex_watchdog_stalled_suspect` count in trace.md to calibrate.
- **`result --json` exit code 275 not stable across codex-companion versions** — the helper is reading an undocumented error contract. Mitigation: helper matches both exit-code 275 AND error-message regex `/No (?:finished )?job found/`. Smoke can't catch this drift; trace-tag a `phase_<N>_codex_watchdog_unexpected_result_shape` whenever the helper sees a non-275 non-zero from `result` so it surfaces.
- **Cancel itself hangs** — `node "$CODEX_COMPANION" cancel` could potentially hang for the same upstream reason. Mitigation: pipe through `timeout 30 node ...` (GNU coreutils `timeout` is universally available on the platforms we support). If even cancel times out, the trace surfaces and the operator can `pkill` manually — same fallback the user already has today.
- **Per-cwd broker leak** — when watchdog escalates and the user picks Abort, the broker process and codex CLI children may still be alive (they're long-running daemons, not per-job). Same situation as today — the user's Claude Code session exit cleans them up. Not adding new cleanup logic; out of scope.

---

## Out-of-band: how the diagnostic was captured

For the curious: the investigation that produced this plan ran in this same conversation on 2026-05-03. Method, in case the diagnosis ever needs re-running:

1. Inspect the review's `trace.md` for the abort tag. Extract reviews-root + review-id from the `~/.adams-reviews/<repo-slug>/<branch>/<review_id>/` path.
2. Read `.codex-jobs.json` for the seven job IDs and `.launch-L*.json` for one logFile path. The codex state directory follows `~/.claude/plugins/data/codex-openai-codex/state/<cwd-slug-with-hash>/`.
3. Read each `<job-id>.log` and `<job-id>.json` in that state dir. The smoking gun is "thread not found" at cancel time + every job's log mtime stopping in the same ~7s window.
4. Check whether codex CLI processes are still alive: `ps -ef | grep -E 'codex|app-server'`. If alive after the user's wall-clock observation, the failure is "wedged on a network wait," not "crashed."
5. Run a fresh `node "$CODEX_COMPANION" task --background --effort high --prompt-file <small-prompt>` from any cwd to confirm whether the failure reproduces. If it doesn't (as in our case), conclude "transient upstream" — the watchdog is the right defense.

These steps belong in this plan (not a runbook elsewhere) because they're tied to *this* bug class. If we ship the watchdog and a different codex failure surfaces later, future-me re-runs the same investigation and updates this section.
