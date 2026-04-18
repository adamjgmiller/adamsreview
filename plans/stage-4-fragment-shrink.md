# Stage 4 plan — Fragment shrink + helper externalization

**Status:** not started. Extracted from `docs/BUILD.md` during the 2026-04-18 docs reorganization so that the last unexecuted scope survives outside the archived build journal.

**Plan-approval round-trip required** before execution (non-trivial representational change across many files).

---

## Rationale

`/adams-review` invocation currently expands to ~30k tokens of command + fragments alone (`commands/adams-review.md` inlines 10 fragments via `!cat` preprocessor; total ~117k chars / 2876 lines at Stage 2.6 close). On top of the Claude Code harness + user's MCP/plugin surface, a typical session lands at 90k+ context before any review work runs.

Stage 2.5 cross-stage notes flagged this as "Lever #4: fragment prose shrink — deferred"; Stage 2.6's Phase-0 expansion (step 0.2a added ~4k chars of inline Bash) nudged the number further. This stage executes the deferred work plus its natural companion: moving cohesive Bash snippets out of fragments and into helper scripts with 10-line contracts.

## Baseline to beat (post-Stage-2.6, 2026-04-18)

```
commands/adams-review.md                 171 lines    8k chars
commands/_shared/00-preflight.md         617 lines   26k chars   ← biggest
commands/_shared/01-detection.md         399 lines   17k chars
commands/_shared/02-ensemble-adapter.md  359 lines   14k chars
commands/_shared/03-dedup.md             206 lines    7k chars
commands/_shared/04-scoring-gate.md      213 lines    8k chars
commands/_shared/05-validation.md        381 lines   17k chars
commands/_shared/06-cross-cutting.md     164 lines    6k chars
commands/_shared/07-finalize.md          285 lines   10k chars
commands/_shared/lens-{ux,security}-reference.md  81 lines 4k chars
TOTAL                                   2876 lines  117k chars  ≈ 30k tokens
```

Re-measure at stage close and record before/after in the stage's close-out notes so future stages can tell whether they're re-expanding.

## Scope

### 4.A — Prose compression pass across fragments

- Remove prose that duplicates the top-level `adams-review.md` prelude (sub-agent dispatch pattern, working-set rules, effort-is-session-wide are repeated inside fragments in abbreviated form).
- Collapse parallel wording across L1–L6 lens prompts. Each currently repeats the same "Read ONLY the diff between `$comparison_ref` and HEAD…" / "Return a JSON array of candidates…" scaffolding with minor variations. Factor the invariant parts into step 1.2's shared input block, leave only lens-specific guidance in each L*N* prompt.
- Tighten working-set tables into the `docs/DESIGN.md` §25.1 reference rather than reproducing them in full at each fragment's tail.
- **Target.** ≥25% char reduction on `00-preflight.md` and `01-detection.md` (the two biggest); ~15-20% on the rest.

### 4.B — Extract inline Bash snippets into helper scripts

Candidate extraction points, each yielding a ~10-line fragment contract + one helper invocation:

1. **`freshness-gate.sh`** — step 0.2a's full fetch + 30s-timeout + FF + behind-count + AskUserQuestion-branching Bash (~80 lines of snippet). Helper takes `--base-branch` + `--head-branch`, returns JSON with `{comparison_ref, base_freshness, remote_sha, behind_count, preflight_warnings[]}`. Fragment reduces to the AskUserQuestion dispatch + helper invocation.
2. **`trivial-check.sh`** — step 0.11's extension-allowlist + line-count + file-count Bash (~20 lines). Helper returns `{trivial_mode: bool, reason: string}`.
3. **`dirty-tree-classify.sh`** — step 0.8's `git status --porcelain` categorization into Modified/Staged/Untracked (~15 lines). Helper returns JSON.
4. **`finding-builder.py`** (candidate) — step 1.4 list-step-3's jq-builder that transforms a partial lens candidate into a full schema-shaped finding. Currently ~40 lines of jq inside the fragment. A Python helper could take a partial JSON + lens metadata and return the full finding, simplifying the fragment to `full=$(finding-builder.py --lens L2-structural --candidate … --counter-state …)`.

### Not in scope for this stage

- Lens reference file inlining gate (only load `lens-ux-reference.md` when L5 actually runs). Lower priority; separate audit.
- Any behavior change — purely representational.
- Any plugin/MCP pruning — user-level decision, not ours.
- Any `docs/DESIGN.md` rev bump; clarification-level updates only (§21 gains rows for new helpers).

## Done when

1. Command + fragments drop from ~30k tokens to ≤~22k tokens (≥25% reduction target). Measured via the same `wc -c` snapshot at stage close.
2. `test/smoke.sh` passes unchanged — no behavior drift. Smoke tests may grow to cover new helpers' contracts (fresh scratch-repo fixtures for `freshness-gate.sh`, etc.) but existing assertions stay green.
3. Stage close-out records the before/after character and token counts.
4. Each extracted helper has 2-3 smoke assertions covering its happy path + one failure mode (mirrors the OC-* / FR-* / RH-* style from Stage 2.6).
5. `docs/DESIGN.md` §21 gains entries for each new helper (interface, algorithm sketch, error cases) — same shape as existing §21.1–§21.10.

## Commit cadence (estimated)

1. 4.A prose compression — 2-3 commits (one per fragment cluster: preflight+detection first, then validation/dedup/scoring, then finalize/ensemble).
2. 4.B helper extractions — 1 commit per helper (freshness-gate → trivial-check → dirty-tree-classify → finding-builder). Each commit includes fragment shrink + helper + smoke assertions + DESIGN §21 row.
3. Stage 4 close-out — measurement snapshot — 1 commit.

~6-8 commits total.

## Related context to inherit when planning

- `docs/DESIGN.md` §21.1–§21.10 are the existing helper-contract shape to emulate.
- `docs/BUILD.md` Cross-stage notes (2026-04-17 bash-3.2 portability, exit-code conventions, uv shebang pattern) apply to any new helper.
- `CLAUDE.md` Operational rules — new helpers must follow the same pattern (error-as-prompt stderr, `--help`, fixture-replay where relevant).
