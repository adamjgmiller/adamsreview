# Plan: `/adamsreview:codex-review` — Codex-driven counterpart to `/adamsreview:review`

Status: approved 2026-05-01; build in progress on this worktree
Branch: `codex-review` (worktree already in place)
Related CLAUDE.md sections to update: pipeline shape (add the new command + its phase shape), helper index (no new helpers — reuses everything), recommended flow (note codex-review as a peer entrypoint that produces the same artifact).
Related schema/helper changes: no schema changes; possibly extract shared lens-prompt blockquotes to `fragments/lens-prompts/L{1..7}.md` so both commands consume one source of truth (decided during build).

## Context

`/adamsreview:review` runs six (seven under `--ensemble`) Claude sub-agent lenses for Phase 1 detection and Opus validators for Phase 4. The user wants a sibling command that does the same review shape but with **Codex** as the primary review/validation engine, while keeping Claude (Sonnet) for the orchestration glue Codex is poor at: dedup, batched scoring, and shape-fixing freeform Codex output into the structured artifact schema.

Why a separate command rather than a flag: putting this behind `--codex` on `commands/review.md` would bloat that command's `allowed-tools` line and fragment graph for a mode the user doesn't always want loaded. A separate command keeps both files lean.

Why now: Codex (via `codex-companion.mjs task --background`) is already plumbed into the `--ensemble` path as one of three external sources. Promoting it from "extra signal pooled with CodeRabbit" to "primary detection/validation engine" gives a fully independent Codex review whose findings flow into the same lifecycle (`/adamsreview:fix`, `:add`, `:walkthrough`, `:promote`) without changes to those commands.

Outcome: `/adamsreview:codex-review [--effort <level>] [--full]` produces an `artifact.json` at the standard path (`~/.adams-reviews/<repo-slug>/<branch>/<review_id>/`) that is a drop-in for everything downstream, marked `reviewer_sources: ["internal-codex"]` so the renderer (or a future analytics pass) can distinguish review lineage.

## 1. Goal

A new top-level command that:

1. Reuses the entire Phase 0 preflight contract (branch/PR detection, freshness gate, dirty-tree guard, push, prior-artifact prompt, trivial-mode classification, CLAUDE.md path enumeration, artifact seeding) — no divergence.
2. Replaces Phase 1's six/seven Claude lens dispatches with **seven parallel Codex jobs** (L1–L7), each launched via the existing `codex-companion.mjs task --background --effort <level> --prompt-file <file>` primitive. L7 holistic always runs (codex-review's analog to the `--ensemble`-only L7 in `:review`).
3. Skips Phase 1.5 entirely. Codex-review has no `--ensemble`; no CodeRabbit, no PR scrape, no third-party comment pooling.
4. Reuses Phase 2 (Sonnet dedup) and Phase 3 (chunked-batch Sonnet scoring) verbatim — Codex doesn't pay rent on the operations Claude is already efficient at.
5. Replaces Phase 4a deep validation with **one parallel Codex job per surviving finding** (10–25 typical). Each Codex output runs through a small per-finding **Sonnet shape-fixer** that emits the canonical `validation_result` tuple. Tuples concatenate into the existing `--apply-decisions --expected $N` batch.
6. Replaces Phase 4b light confirmation with **chunked-batch Codex** (≤25 candidates per chunk, parallel chunks). Each chunk's output runs through a chunk-level Sonnet shape-fixer.
7. Replaces Phase 5 cross-cutting with **one Codex pass** + Sonnet shape-fixer.
8. Reuses Phase 6 (finalize/render/publish) verbatim. Same artifact path, schema, PR comment publish flow, token tally helpers.

Concrete invocation examples:

- `/adamsreview:codex-review` — default, `--effort high`, full pipeline.
- `/adamsreview:codex-review --effort medium` — cheaper/faster routine review.
- `/adamsreview:codex-review --full --effort xhigh` — disable trivial-mode short-circuit, max effort. Most expensive setting.

## 2. Non-goals / explicitly deferred

- **No `--ensemble` flag.** codex-review is purpose-built for Codex purity. If the user wants CodeRabbit + PR scrape pooling, that's `/adamsreview:review --ensemble`. Mixing the two is out of scope.
- **No new artifact schema fields.** `reviewer_sources: ["internal-codex"]` uses the existing array; downstream commands read disposition + score, not source.
- **No changes to `/adamsreview:fix`, `:add`, `:walkthrough`, `:promote`.** Same artifact path → no consumer changes. (One small renderer/CLAUDE.md note is fine; downstream code paths don't branch on source.)
- **No new helpers.** Reuse `artifact-seed.sh`, `artifact-patch.py`, `artifact-render.py`, `artifact-publish.sh`, `freshness-gate.sh`, `staleness.sh`, `claude-md-paths.sh`, `origin-crosscheck.sh`, `line-range-check.sh`, `prior-fix-diff.sh`, `assign-finding-ids.sh`, `parse-with-repair.py`, `parse-validator-result.py`, `source-family-map.py`, `tally-subagent-tokens.sh`, `orchestrator-tokens.sh`. The codex-companion script is also already discoverable via the same probe used in §1.2a today.
- **No Wave 2 chain-retry on Codex.** Same as `/adamsreview:add` — bounded scope keeps wall-clock predictable.
- **No "fallback to Claude" if Codex unavailable.** If the codex-companion probe fails, the command aborts cleanly with the same setup hint the existing §1.2a gate emits. Codex-review is Codex; degrading to Claude would defeat the point.

## 3. Key design decisions

### 3.1 Separate command file; share fragments via extraction

`commands/codex-review.md` mirrors `commands/review.md`'s shape but loads codex-specific phase fragments. Fragment authoring strategy:

- **Phase 0**: load `fragments/00-preflight.md` verbatim (no divergence from `:review`).
- **Phase 1 (Codex)**: new `fragments/01-codex-detection.md` that mirrors §1.1–§1.6 of `01-detection.md` but dispatches Codex jobs instead of `Agent` blocks. The lens prompt blockquotes (§1.3.1–§1.3.7) get extracted to `fragments/lens-prompts/L{1..7}.md` so both `01-detection.md` and `01-codex-detection.md` `Read`-include the same source. (One-time refactor that pays off: lens prompts are ~700 lines combined; without extraction we'd diverge over time.)
- **Phase 2/3**: load `fragments/03-dedup.md` and `fragments/04-scoring-gate.md` verbatim.
- **Phase 4 (Codex)**: new `fragments/05-codex-validation.md` mirroring `05-validation.md` §4.1–§4.7 but dispatching Codex jobs and Sonnet shape-fixers. Pre-existing override re-assertion (§4.6) and tally (§4.7) are reused unchanged.
- **Phase 5 (Codex)**: new `fragments/06-codex-cross-cutting.md` — one Codex pass + Sonnet shape-fixer.
- **Phase 6**: load `fragments/07-finalize.md` verbatim.

### 3.2 Codex dispatch via codex-companion's job model

Every Codex run uses:

```
node "$CODEX_COMPANION" task --background --effort "$effort" --prompt-file "$prompt_file"
```

Capture the returned `job_id`. Poll via `node "$CODEX_COMPANION" status <job_id> --json` until terminal; fetch the output via `node "$CODEX_COMPANION" result <job_id> --json`. This sidesteps the raw `codex exec` + sentinel-file pattern in `~/.claude/skills/codex-consult/SKILL.md` — the companion already encodes the launch/wait/cleanup contract.

The orchestrator dispatches all jobs in a phase in **one orchestrator turn**, captures each job_id into a `{slot → job_id}` map, then on subsequent turns polls each via `status --json` until all are terminal. The codex-companion's job tracking makes this clean (no sentinel files for the orchestrator to manage).

### 3.3 Phase 1: 7 parallel Codex lenses, one combined Sonnet normalizer

Trivial-mode skip rules unchanged: L2/L5/L6/L7 skip when `trivial_mode == true` and `force_full != true`. So a trivial-mode review is 3 Codex jobs (L1/L3/L4); a full review is 7.

Each lens prompt is the **verbatim L1–L7 blockquote** from today's `01-detection.md` (extracted to `fragments/lens-prompts/L{1..7}.md` per §3.1). Codex receives `<shared invariants from §1.2.1> + <lens blockquote>` as the prompt body, written to `/tmp/adams-review-codex-<review_id>-L<N>.md`.

Inputs Codex needs:
- The diff (`git diff $comparison_ref..HEAD`) — referenced in the prompt; Codex can run the command itself via its filesystem access.
- CLAUDE.md content for L3/L4/L5 — embed as prompt context (Codex won't reliably traverse to find them).
- L2's prior-fix suspect array (from `prior-fix-diff.sh`) — embed as prompt context.

After all 7 jobs terminate, **one combined Sonnet normalizer** sub-agent ingests all 7 stdouts (concatenated with lens-id headers) and emits a unified candidate JSON array tagged with `source_family` and `impact_type` per the lens that produced each candidate. This mirrors the Phase 1.5 ensemble-adapter pattern at `02-ensemble-adapter.md:222-280` exactly.

After the normalizer:
- `parse-with-repair.py` front-stops the JSON.
- Schema-guard repair for missing `file`/`line_range` (same `(unknown)` / `[1,1]` defaults).
- `assign-finding-ids.sh` → IDs.
- `origin-crosscheck.sh` → blame-trace correction.
- `line-range-check.sh` → drop hallucinated ranges.
- `artifact-patch.py --add-findings` → atomic batched commit.

### 3.4 Phase 4a: one Codex per finding + per-finding Sonnet shape-fixer

For each surviving deep-lane (correctness/security) finding:

1. Build a Codex prompt that embeds the finding's claim, file:line, evidence_snippet, and instructs Codex to do blast-radius validation (same prompt body as today's Opus validator, ported to Codex idiom — written verbatim then iterated based on output quality during build/calibration).
2. Launch Codex via `task --background --effort $effort --prompt-file <file>`.
3. After all jobs terminate, dispatch one **Sonnet shape-fixer** sub-agent per finding. Its prompt is small: "Here is one Codex validation output. Emit a single JSON object matching this schema: `{score_phase4, actionability, confirmed_strength, decision, notes, validation_result, related_candidates_to_investigate}`."
4. Concatenate all tuples → `artifact-patch.py --apply-decisions --expected $N`.

Per-finding atomicity: if one Codex job fails unrecoverably or its shape-fixer can't produce a valid tuple, that **single finding** drops to `disposition: uncertain` (score_phase4: null). The other 9–24 findings still apply cleanly via the batched apply. This is why per-finding shape-fixers beat one combined fixer: the contract `--expected $N` requires perfect tuple count, and a combined fixer that drops one input poisons the whole batch.

### 3.5 Phase 4b: chunked-batch Codex (≤25 per chunk) + chunk-level Sonnet shape-fixer

Same shape as today's Sonnet-light chunk-agents. For each chunk of ≤25 light-lane candidates:

1. Build one Codex prompt that lists all candidates and asks for a single JSON array of confirmation tuples.
2. Launch Codex; await termination.
3. Dispatch one Sonnet shape-fixer per chunk that takes the freeform Codex output and emits the JSON tuple array.
4. Concatenate across chunks → `--apply-decisions`.

Chunk failure dropping all candidates in that chunk to `disposition: uncertain` is acceptable — light-lane is shallow anyway, and the failure surface is small.

### 3.6 Phase 5: one Codex pass + one Sonnet shape-fixer

One Codex job reads the confirmed-findings list (file paths + claims + impact types) and proposes cross-cutting groups. Output runs through one Sonnet shape-fixer that emits the `cross_cutting_groups` array per `bin/schema-v1.json#/$defs/cross_cutting_group`.

### 3.7 Adaptive retry-with-orchestrator-judgment

For every Codex job, the orchestrator follows this policy (encoded as prose in the relevant fragments — not a deterministic helper):

1. On non-zero exit / timeout / clearly malformed output, the orchestrator inspects the failure context. If the failure looks transient (rate limit, single-output JSON glitch, sentinel never written despite exit=0), retry up to **3 times** with the same prompt.
2. If all 3 retries exhibit the same failure mode, treat as unrecoverable. Drop the affected unit (lens / finding / chunk) and **escalate to the user via `AskUserQuestion`** with options:
   - **Continue with degraded coverage** (e.g., "L2 failed; continue with 6 lenses; some structural bugs may be missed")
   - **Abort the run** (preserves `attempted` state if applicable, returns control to user)
3. On `AskUserQuestion` continue, log the drop to `trace.md` with tag `phase_<N>_codex_dropped:<unit_id>` and proceed.

Mirror the existing `phase_1_5_codex_failed` audit-tag style in `02-ensemble-adapter.md:140`. The ask-once-on-unrecoverable policy avoids 30 prompts per review while keeping the user in the loop when the review is materially degraded.

### 3.8 Token accounting

- **Codex spend**: NOT logged to `tokens.jsonl`. Mirrors the Phase 1.5 precedent — Codex billing is provider-side, outside the `subagent_tokens` rollup.
- **Sonnet spend** (normalizer + per-finding shape-fixers + chunk shape-fixers + cross-cutting shape-fixer + dedup + scoring): logged via `log-tokens.sh` under phase tags `phase_1`, `phase_2`, `phase_3`, `phase_4a`, `phase_4b`, `phase_5`. Rolled into `subagent_tokens` at Phase 6 finalize via the existing `tally-subagent-tokens.sh` invocation.
- **Orchestrator tokens**: Same opt-in path (`ADAMS_REVIEW_TALLY_ORCHESTRATOR=1` → `orchestrator-tokens.sh`) as `:review`. No code change.

### 3.9 `reviewer_sources` marker

Phase 0's `artifact-seed.sh` invocation in codex-review's preflight passes `--reviewer-sources` (a new optional flag — one-line addition to the helper, defaults to `["internal"]` when absent) so the seeded artifact carries `reviewer_sources: ["internal-codex"]`. Renderer continues to ignore it (today's render doesn't surface this field); future renderer work could add a "reviewed by Codex" header line if useful.

If `assign-finding-ids.sh` or other helpers care about source family, they read `source_family` on the candidate, not `reviewer_sources` on the artifact — no behavioral change downstream.

## 4. Implementation outline

Build order keeps each step independently smoke-testable. Because both `:review` (post-refactor) and `:codex-review` will be tested before merge from this same branch, the foundation refactor and the new command land as separate commits in this worktree but ship together.

### 4.1 Foundation refactor

1. Extract lens prompts to `fragments/lens-prompts/L{1..7}.md`. Update `fragments/01-detection.md` to `Read`-include them (per CLAUDE.md operational rule 10's manifest-style directive). Smoke green proves `:review` still works.
2. Tiny one-line addition to `bin/artifact-seed.sh`: optional `--reviewer-sources` flag (default `["internal"]`). Smoke + 1 new assertion.

### 4.2 codex-companion job-poll helper (optional, one new helper)

Decide during build whether the polling pattern is small enough to inline in fragments (likely yes — `node $CODEX_COMPANION status <id> --json | jq -r '.state'` is two lines). If not, extract to `bin/codex-job-await.sh` that polls until terminal and emits `{job_id, exit_code, output_path}`. New helper would add ~3 smoke assertions.

### 4.3 commands/codex-review.md + Phase 1 Codex fragment

1. Author `commands/codex-review.md` (mirrors `commands/review.md` shape; smaller `allowed-tools` since no CodeRabbit/PR-scrape grants needed).
2. Author `fragments/01-codex-detection.md` — Phase 1 Codex dispatch + combined Sonnet normalizer + standard join step.
3. Smoke test: dry-run a trivial-mode review on a tiny test fixture; assert artifact written, findings array populated.

### 4.4 Phase 4 Codex fragment

1. Author `fragments/05-codex-validation.md` — Phase 4a per-finding Codex + per-finding Sonnet shape-fixer; Phase 4b chunked-batch Codex + chunk-level Sonnet shape-fixer.
2. Smoke: validation runs against a fixture with N=3 deep + 5 light candidates; assert all 3 deep tuples and 1 light chunk tuple array apply cleanly.

### 4.5 Phase 5 Codex fragment

Author `fragments/06-codex-cross-cutting.md` — one Codex + one Sonnet shape-fixer. Smoke: fixture with 4 confirmed findings clustering into 2 groups; assert `cross_cutting_groups` populated.

### 4.6 End-to-end smoke + CLAUDE.md update

1. New smoke fixture: a small repo with a deliberate handful of bugs across correctness/security/ux/policy. Run `/adamsreview:codex-review` end-to-end against the fixture in CI.
2. Update `CLAUDE.md`:
   - Pipeline shape: add a `/adamsreview:codex-review` block alongside `/adamsreview:review`.
   - Recommended flow: note codex-review as a peer entrypoint.
   - Layout: add `commands/codex-review.md` and the new fragments to the tree.
3. Bump `.claude-plugin/plugin.json` version (minor — new command).

### 4.7 Real-PR validation

User-driven before merge: run `/adamsreview:review` (regression-check the lens-prompt extraction) and `/adamsreview:codex-review` (smoke the new command end-to-end) against a real PR each. Capture comparison in `docs/case-studies/` after merge if useful for prompt-tuning.

## 5. Critical files

- **New**: `commands/codex-review.md`, `fragments/01-codex-detection.md`, `fragments/05-codex-validation.md`, `fragments/06-codex-cross-cutting.md`, `fragments/lens-prompts/L{1..7}.md` (extracted; shared with `:review`).
- **Modified**: `fragments/01-detection.md` (replace inline lens blockquotes with `Read`-include directives), `bin/artifact-seed.sh` (one new optional flag), `CLAUDE.md` (sections noted in 4.6), `.claude-plugin/plugin.json` (version bump), `test/smoke.sh` (new assertions).
- **Reused unchanged**: `bin/artifact-patch.py`, `bin/artifact-render.py`, `bin/artifact-publish.sh`, `bin/artifact-validate.sh`, `bin/artifact-read.sh`, `bin/freshness-gate.sh`, `bin/staleness.sh`, `bin/claude-md-paths.sh`, `bin/origin-crosscheck.sh`, `bin/line-range-check.sh`, `bin/prior-fix-diff.sh`, `bin/assign-finding-ids.sh`, `bin/parse-with-repair.py`, `bin/parse-validator-result.py`, `bin/source-family-map.py`, `bin/tally-subagent-tokens.sh`, `bin/orchestrator-tokens.sh`, `bin/log-phase.sh`, `bin/log-tokens.sh`, `bin/repo-slug.sh`, `bin/trivial-check.sh`, `fragments/00-preflight.md`, `fragments/03-dedup.md`, `fragments/04-scoring-gate.md`, `fragments/07-finalize.md`.

## 6. Verification

End-to-end:

1. `test/smoke.sh` green with new assertions for: (a) `artifact-seed.sh --reviewer-sources` flag round-trip; (b) lens-prompt extraction round-trip (`:review` smoke still green); (c) Phase 1 Codex normalizer parses fixture stdout into candidates; (d) Phase 4a per-finding shape-fixer produces a valid tuple from fixture Codex output; (e) Phase 4b chunked shape-fixer produces a tuple array; (f) Phase 5 cross-cutting fixer produces valid groups.
2. Author-time real-PR run: codex-review against a recent merged PR; compare to `:review` baseline; spot-check 3–5 findings per side for quality parity.
3. Lifecycle smoke: after a successful codex-review, run `/adamsreview:fix` against the produced artifact; assert it processes findings normally (no source-family-related branch trips).
4. Failure-mode smoke: deliberately point one lens at a malformed prompt to force a Codex error; assert the orchestrator surfaces the `AskUserQuestion` escalation after 3 retries.

Quality calibration:

- After implementation, log `(found_count, confirmed_count, false_positive_rate)` per phase across the first N real reviews. Compare to `:review`'s baselines from `phases.jsonl`. If codex-review's confirmed-rate is materially lower at the same effort, tune Codex prompts (most likely L2 and Phase 4a, the deepest reads).

## 7. Risks and mitigations

- **Wall-clock**: ~25–40 min/review at `--effort high`. Mitigation: `--effort medium` for routine use; document the cost/quality table once we have data.
- **Codex output drift outpaces Sonnet shape-fixer**: per-finding atomicity means worst-case is N findings dropped to `uncertain`, not a broken artifact. Mitigation: monitor `disposition: uncertain` rate; if it spikes, harden shape-fixer prompts.
- **codex-companion API churn**: the companion is third-party (openai-codex plugin). Pin minimum version in the readiness probe. Mitigation: same probe pattern as §1.2a today; failure exits cleanly with a setup hint.
- **Lens-prompt extraction merge conflicts**: extraction touches `01-detection.md` heavily. Mitigation: land foundation refactor (§4.1) first as its own commit, smoke green, then build codex-review on top.
