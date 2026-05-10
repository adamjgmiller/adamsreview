---
allowed-tools: Bash(artifact-read.sh:*), Bash(artifact-patch.py:*), Bash(artifact-validate.sh:*), Bash(artifact-render.py:*), Bash(artifact-publish.sh:*), Bash(claude-md-paths.sh:*), Bash(staleness.sh:*), Bash(prior-fix-diff.sh:*), Bash(line-range-check.sh:*), Bash(assign-finding-ids.sh:*), Bash(origin-crosscheck.sh:*), Bash(parse-with-repair.py:*), Bash(parse-validator-result.py:*), Bash(source-family-map.py:*), Bash(log-phase.sh:*), Bash(log-tokens.sh:*), Bash(tally-subagent-tokens.sh:*), Bash(orchestrator-tokens.sh:*), Bash(repo-slug.sh:*), Bash(freshness-gate.sh:*), Bash(trivial-check.sh:*), Bash(artifact-seed.sh:*), Bash(codex-poll.sh:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(mktemp:*), Bash(cat:*), Bash(printf:*), Bash(echo:*), Bash(grep:*), Bash(awk:*), Bash(sed:*), Bash(tr:*), Bash(wc:*), Bash(head:*), Bash(tail:*), Bash(cut:*), Bash(sort:*), Bash(diff:*), Bash(openssl:*), Bash(python3:*), Bash(node:*), Bash(find:*), AskUserQuestion, Agent, Read, BashOutput, KillShell
argument-hint: "[--effort <low|medium|high|xhigh>] [--full]"
description: Codex-driven deep code review producing the same artifact.json shape as :review (drop-in for /adamsreview:fix, :add, :walkthrough, :promote).
disable-model-invocation: false
---

Flags (optional):
- `--effort <level>` controls Codex reasoning depth (`low`, `medium`,
  `high`, `xhigh`). Default `high`. Higher = deeper analysis but
  longer wall-clock and higher cost.
- `--full` forces `trivial_mode=false` for this run (overrides the
  doc/config-PR early-exit). Same semantics as `:review --full`.

Note: this command has **no `--ensemble` flag** — it is purpose-built
for Codex-only review. If you want internal Claude lenses pooled with
the Codex CLI + a PR bot-comment scrape, run `/adamsreview:review
--ensemble` instead.

**Read `fragments/_prelude-shared.md` before proceeding — it lists
rules that apply to every phase below (sub-agent return handling,
helper-script error-as-prompt).**

## Execution overview

This command orchestrates the same phases as `/adamsreview:review`
(Phases 0–6 plus Phase 5.5 auto-fix-hint generation), swapping the
Claude sub-agent dispatches for **Codex jobs** (via the
`codex-companion.mjs` plugin's `task --background` primitive) at:

- **Phase 1 detection** — 7 parallel Codex lenses (L1–L7) instead of
  Claude `Agent` blocks.
- **Phase 4a deep validation** — one parallel Codex job per surviving
  finding instead of one Opus sub-agent per finding.
- **Phase 4b light confirmation** — chunked-batch Codex (≤25 candidates
  per chunk) instead of chunked-batch Sonnet.
- **Phase 5 cross-cutting** — one Codex pass instead of one Opus pass.

Claude sub-agents (Sonnet) are still used for the "shape-fixer" /
normalizer / dedup / scoring work where structured output matters
more than reasoning depth — all of these phases execute the SAME
fragments as `:review`:

- **Phase 0 preflight** — `fragments/00-preflight.md` verbatim.
- **Phase 2 dedup** — `fragments/03-dedup.md` verbatim.
- **Phase 3 scoring gate** — `fragments/04-scoring-gate.md` verbatim.
- **Phase 6 finalize** — `fragments/07-finalize.md` verbatim.

Each phase below is defined in a fragment under `fragments/NN-<name>.md`.
At each phase boundary, read the named fragment with the `Read` tool
and execute the instructions inside before proceeding to the next phase.

**Before you start, build a TaskList that mirrors the phases below**
(one task per phase, plus one for argument parsing). Mark each
`in_progress` when you start it and `completed` when you finish.

If a phase genuinely cannot run, mark the task `completed` with a
one-line `trace.md` note and move on. Phase 6 (finalize) runs
unconditionally — a partial review is still worth rendering and
publishing so the user can inspect what did succeed.

Codex job failures (non-zero exit, malformed output, sentinel timeout)
are handled per the **adaptive retry-with-orchestrator-judgment**
policy: retry up to 3 times with the same prompt; on persistent
failure, drop the affected unit (lens / finding / chunk) and escalate
to the user via `AskUserQuestion` ("L2 failed; continue with 6 lenses
or abort?"). Log every drop to `trace.md` with tag
`phase_<N>_codex_dropped:<unit_id>`. This policy is restated where it
applies in each Codex-using fragment.

## Sub-agent dispatch pattern

Two dispatch primitives in this command:

**Codex jobs** (the heavy reviewer/validator work):

```
node "$CODEX_COMPANION" task --background --effort "$effort" \
    --prompt-file "/tmp/adams-review-codex-<review_id>-<slot>.md"
```

The companion returns the launch payload on stdout (extract the id
with `jq -r '.jobId'`). Launch ALL jobs in a phase within a SINGLE
orchestrator turn so they run concurrently; polling happens on
subsequent turns.

**Polling and result fetch go through `codex-poll.sh` exclusively.**
The helper is the single source of truth for codex-job liveness — it
wraps `status --json`, runs the two-signal stall check (logFile mtime
+ `result --json` desync probe), enforces the per-effort wall-clock
ceiling, and on `completed` plucks the freeform output via the
documented `.storedJob.result.rawOutput` chain (with the
`// .storedJob.payload.rawOutput // .storedJob.rawOutput // ""`
fallback for older companion shapes and partial-failure records).
**Do NOT call `node "$CODEX_COMPANION" status` or `result` directly
anywhere** in this command's prose, fragment substitutions, or
follow-up turn instructions — direct calls bypass the watchdog and
reintroduce the indefinite-`running` failure mode (real failure
2026-05-03; see `plans/codex-watchdog.md`). Phase fragments §1.4 /
§4.2.3 / §4.3.2 / §5.2.2 specify the exact `codex-poll.sh` invocation
shape per phase. Smoke `CR-13c` and `CR-13f` enforce this — fragment
*and* command files are scanned for raw `node "$CODEX_COMPANION"
status` recipes.

`CODEX_COMPANION` is discovered the same way as in
`fragments/01-detection.md` step 1.2a — see that block for the
readiness probe.

**Claude sub-agents** (Sonnet shape-fixers, normalizer, dedup, scoring):

Every `Agent` tool-use specifies:
- `subagent_type: general-purpose`
- `model: sonnet` (default for shape-fixer / normalizer roles in this
  command — Phase 3 scoring uses chunked-batch Sonnet exactly as
  `:review` does)

Parallel fan-outs happen by firing multiple Agent tool-use blocks in a
single orchestrator turn.

## Argument handling

Parse `$ARGUMENTS` (whitespace-split) for:
- `--effort <value>` → `effort=<value>` (validate against `low|medium|high|xhigh`; reject other values with a usage message)
- `--full` → `force_full=true` (else `false`)
- Any other token → stop and ask the user to clarify.

If `--effort` is omitted, set `effort=high`.

Set the following working-context values BEFORE executing Phase 0:

- `effort` (default `high`) — used by every Codex `task` invocation in
  Phases 1, 4a, 4b, 5.
- `force_full` (default `false`) — consumed by Phase 0 step 0.11.
- `reviewer_sources_label="internal-codex"` — consumed by Phase 0 step
  0.15 (the orchestrator passes it to `artifact-seed.sh
  --reviewer-sources` so the seeded artifact carries
  `reviewer_sources: ["internal-codex"]`).
- `ensemble_mode=false` — codex-review never runs the ensemble adapter;
  setting this explicitly keeps fragments shared with `:review` from
  branching on an undefined value.

## Codex readiness gate

Before Phase 0, probe codex-companion availability. This mirrors
`fragments/01-detection.md` step 1.2a's Codex probe but is **fatal**
in codex-review (vs. the soft `proceed-without` option in `:review
--ensemble`):

```bash
CODEX_COMPANION="$(find ~/.claude/plugins -type f -name codex-companion.mjs -path '*codex*' 2>/dev/null | head -1)"
if [[ -z "$CODEX_COMPANION" ]]; then
    echo "ERROR: codex-companion script not found." >&2
    echo "Action: install the openai-codex plugin and run /codex:setup." >&2
    exit 1
fi

codex_setup_json=$(node "$CODEX_COMPANION" setup --json 2>&1)
if [[ "$(jq -r '.ready // false' <<<"$codex_setup_json" 2>/dev/null)" != "true" ]]; then
    echo "ERROR: codex-companion setup --json reports not-ready." >&2
    echo "Action: run /codex:setup to diagnose." >&2
    echo "$codex_setup_json" >&2
    exit 1
fi
```

Capture `CODEX_COMPANION` in working context. Codex is the engine —
no fallback to Claude lenses; failing here exits cleanly so the user
can fix setup before any token spend.

---

**Phase 0 — Preflight.** Read `fragments/00-preflight.md` and execute
the instructions inside before proceeding to Phase 1.

---

**Phase 1 — Codex detection.** Read `fragments/01-codex-detection.md`
and execute the instructions inside before proceeding to Phase 2.

---

**Phase 1.5 — Skipped.** codex-review has no `--ensemble`; no
external sources are pooled. Log one line to `trace.md`:

```
Phase 1.5 skipped — /adamsreview:codex-review has no external sources
```

---

**Phase 2 — Dedup.** Read `fragments/03-dedup.md` and execute the
instructions inside before proceeding to Phase 3.

---

**Phase 3 — Scoring gate.** Read `fragments/04-scoring-gate.md` and
execute the instructions inside before proceeding to Phase 4.

---

**Phase 4 — Codex validation.** Read `fragments/05-codex-validation.md`
and execute the instructions inside before proceeding to Phase 5.

---

**Phase 5 — Codex cross-cutting.** Read `fragments/06-codex-cross-cutting.md`
and execute the instructions inside before proceeding to Phase 5.5.

---

**Phase 5.5 — Auto-fix-hint generation.** Read
`fragments/06b-auto-fix-hint.md` and execute the instructions inside
before proceeding to Phase 6. Same fragment as `:review` — it's
Sonnet-driven and validator-agnostic, so the codex-review path runs
it identically once Phase 5's cross-cutting (Codex variant) has
returned.

---

**Phase 6 — Finalize.** Read `fragments/07-finalize.md` and execute
the instructions inside.

---

## What this command does NOT do

- No git operations except a single `git push` in Phase 0 step 0.9 (PR mode only, after user dirty-tree confirmation). No commits, tags, branches, deletes, or renames anywhere in the working tree.
- No review of closed/merged PRs — bail at Phase 0 step 0.4 with a
  user-visible message.
- No fallback to Claude lenses if Codex is unavailable — codex-review
  is Codex-only by design. The readiness gate above exits cleanly with
  a setup hint.
- No Phase 1.5 external-source pooling (PR-comment scrape, secondary
  Codex CLI). Run `/adamsreview:review --ensemble` if you want that on
  top of internal Claude lenses.
