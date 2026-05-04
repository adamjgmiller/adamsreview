# Pipeline detail

Detailed phase trees for each lifecycle command, plus the token-tally semantics.
CLAUDE.md keeps a one-paragraph summary per command; this file is the reference.

## `/adamsreview:review [--ensemble] [--full]`

```
├── Phase 0 — Pre-flight (branch/PR detect, base-branch freshness,
│              branch-behind-base advisory at 0.6a, dirty-tree, push,
│              prior-artifact prompt, record review_started_at,
│              trivial-diff detection, CLAUDE.md path lister)
├── Phase 1    ─┐ Detection (6 parallel lens agents, 7 under --ensemble — L7
│               │   is a holistic Opus safety net; origin cross-check corrects
│               │   blame-traceable verdicts; under --ensemble also invokes the
│               │   CodeRabbit and Codex CLIs as subprocesses via the ensemble
│               │   adapter, feeding their output into the Phase 1.5 normalizer)
├── Phase 1.5  ─┘ External-source pooling (PR-comment scrape: gh api → bot
│                 filter → comment-freshness; merged with --ensemble's
│                 CodeRabbit + Codex CLI output through a single Sonnet
│                 normalizer; ensemble mode only; CLI launches dispatched
│                 jointly with Phase 1, PR scrape deferred to post-CLI)
├── Phase 2 — Dedup (one Sonnet call; merges equivalent candidates, unions source_families)
├── Phase 3 — Cheap scoring + gate (chunked-batch Sonnet err-up rubric, ≤25
│              candidates per chunk-agent; ≥2 families auto-graduate; logs
│              demote_rate + score_phase3_histogram to phases.jsonl for #24 calibration)
├── Phase 4 — Validation (deep Opus per candidate for correctness/security —
│              one Agent per finding, structurally enforced by `--apply-decisions
│              --expected $N`; light Sonnet confirmation for ux/policy/architecture
│              via chunked-batch chunk-agents, ≤25 per chunk)
├── Phase 5 — Cross-cutting review (deep-lane only; dispatched Opus sub-agent)
└── Phase 6 — Finalize (schema-validate, tally-subagent-tokens.sh → subagent_tokens,
               orchestrator-tokens.sh → orchestrator_tokens, phases.jsonl record
               (appended throughout via log-phase.sh; Phase 6's record finalizes),
               render, PR comment POST)
```

## `/adamsreview:codex-review [--effort <low|medium|high|xhigh>] [--full]`

```
├── Codex readiness gate (find codex-companion.mjs; `setup --json` ready?
│     fail-fast — no Claude fallback; suggest /codex:setup on missing/not-ready)
├── Phase 0 — Pre-flight (same fragment as :review; passes `--reviewer-sources
│              internal-codex` to artifact-seed.sh so the seeded artifact
│              carries reviewer_sources: ["internal-codex"])
├── Phase 1 — Codex detection (7 parallel `node $CODEX_COMPANION task
│              --background --effort $effort` jobs, one per lens L1–L7;
│              prompt body = fragments/lens-prompts/_shared-invariants.md +
│              fragments/lens-prompts/L<N>.md with $claude_md_paths and
│              $prior_fix_suspects substituted; poll via codex-poll.sh
│              [stall→cancel→§3.7 retry watchdog]; one combined Sonnet
│              normalizer over all 7 outputs → parse-with-repair + schema-
│              guard + line-range-check + assign-finding-ids +
│              origin-crosscheck + batched --add-findings; adaptive
│              retry-with-judgment policy; AskUserQuestion escalation on
│              degraded coverage)
├── Phase 1.5 — Skipped (codex-review has no --ensemble; no CodeRabbit,
│              no PR-comment scrape — purpose-built for Codex purity)
├── Phase 2 — Dedup (same fragment as :review)
├── Phase 3 — Scoring gate (same fragment as :review)
├── Phase 4 — Codex validation
│   ├── Phase 4a deep — one parallel Codex per finding + per-finding Sonnet
│   │     shape-fixer; per-finding atomicity (one bad output → uncertain
│   │     for that finding only; rest of batch applies via --apply-decisions
│   │     --expected $N); polled via codex-poll.sh [watchdog → sentinel
│   │     uncertain on stall]
│   ├── Phase 4b light — chunked-batch Codex (≤25 per chunk) + per-chunk
│   │     Sonnet shape-fixer; per-chunk atomicity; polled via codex-poll.sh
│   │     [watchdog → sentinel uncertain on stall]
│   ├── Wave 2 — DISABLED (bounded scope per plan; mirrors :add policy)
│   ├── Pre-existing override re-assertion — same as :review
│   └── Tree-cleanliness sweep + summary — same as :review
├── Phase 5 — Codex cross-cutting (one Codex pass over confirmed deep-lane
│              actionable findings + one Sonnet shape-fixer; emits
│              cross_cutting_groups; polled via codex-poll.sh [watchdog →
│              skip Phase 5 on stall — observability, not correctness])
└── Phase 6 — Finalize (same fragment as :review; tally-subagent-tokens.sh
               rolls Sonnet shape-fixer + normalizer spend; Codex tokens
               are NOT in tokens.jsonl — billed externally per Phase 1.5
               precedent)
```

## `/adamsreview:fix [threshold] [--granular-commits]`

```
├── Phase 7 — Load artifact; leftover-attempted abort; clean-tree gate;
│              staleness check; branch-behind-base advisory at 7.6a
├── Phase 8 — Per-fix-group agents edit working tree (no git ops);
│              each group reports files_modified + files_created
└── Phase 9 — Post-fix Opus review pre-commit; aggregate outcomes per group;
              revert regression groups (checkout modified, rm created);
              re-tally subagent_tokens + orchestrator_tokens; commit surviving
              groups with outcome in message (one combined commit by default;
              one per fix group under --granular-commits); push; append
              fix_attempts
              (on 9.pre overlap: offer reconcile | abort | inspect — reconcile
               dispatches one Opus merge agent, collapses fix_groups to FG-RECON
               in memory, then runs Phase 9a/9b/9c unchanged; original
               fix_group_id preserved per-finding in fix_attempts)
```

## `/adamsreview:add [<paste...>] [--file path --line N --claim "..."] [--impact <type>] [--no-dedup]`

```
└── Locate artifact (latest.txt) → leftover-attempted gate →
    branch-behind-base advisory at 3a → build candidates
    (paste-normalizer Sonnet | structured one-shot | mixed) → dedup against
    existing findings (Sonnet, one-direction) → assign IDs continuing past
    max existing F-id (assign-finding-ids.sh --start-from) → --add-finding loop →
    Phase 4 validation lane-aware, NO Wave 2 (Opus deep one-per-candidate /
    Sonnet light chunked-batch ≤25/chunk) → --apply-decisions --expected $N →
    pre-existing override re-assertion (origin=pre_existing AND
    origin_confidence=high → pre_existing_report, regardless of score) →
    re-tally subagent_tokens + orchestrator_tokens → re-render →
    re-publish to existing comment_id → trace + summary
```

## Working set (what each phase establishes)

**`:review` Phase 0** establishes: `review_id` (ULID), `artifact_path` (absolute), `repo_root`, `repo_slug`, `base_branch`, `comparison_ref` (from `freshness-gate.sh` reconciliation — use this, not `base_branch`, for every diff/blame/lens prompt), `reviewed_sha` (post-push), `review_started_at` (ISO-8601 UTC, captured before any push/stash), `mode` (`pr`/`local`), `pr_number`, `trivial_mode`, `reviewed_files_all` (staleness envelope), `claude_md_paths`, and the three append-only log paths (`trace.md`, `phases.jsonl`, `tokens.jsonl`). `comment_id` is set by Phase 6+ on first POST, or rehydrated at Phase 0.14 from a prior artifact.

**`:fix` Phase 7** loads the artifact and adds: `run_id` (ULID, `fixrun_<ULID>`), `threshold`, `latest_known_sha`, `stash_taken`, `input_sha` (pre-edit). Phase 8 adds `eligible_finding_ids` (step 8.1) and `fix_groups` (step 8.3, from `group-fixes.py`). Phase 9 adds `phase_9a_outcomes`, `overlap_files`, `reverted_groups`, `surviving_groups`, `commit_sha`.

Path-handling invariants (helpers receive absolute paths; fragments never assume a cwd; `log-phase.sh` writes to the Phase-0-known path) are operational doctrine — see CLAUDE.md Rule 11.

## Token tally — `subagent_tokens` and `orchestrator_tokens`

Every lifecycle command re-tallies two sibling fields before its final re-render so
the published PR comment reflects cumulative spend across the full review → fix /
add / walkthrough arc:

- **`subagent_tokens`** — rolled up from `tokens.jsonl` (every dispatched sub-agent's
  cost). Captures Phase 1 lenses, Phase 4 validators, Phase 8 fix groups, Phase 9
  post-fix reviewer, etc. External CLIs invoked under `--ensemble` (CodeRabbit,
  Codex) are billed by their own providers and are NOT in `tokens.jsonl` — only
  the Phase 1.5 Sonnet normalizer pass over their output is.
- **`orchestrator_tokens`** — rolled up from the Claude Code session transcript(s)
  under `~/.claude/projects/<cwd-slug>/` (main-session `message.usage` per assistant
  turn, filtered by timestamp ≥ `review_started_at`). Captures what
  `subagent_tokens` deliberately excludes: the orchestrator's own per-turn spend,
  which is what the statusline's live `ctx:` badge is measuring the depth of.
  **Opt-in via `ADAMS_REVIEW_TALLY_ORCHESTRATOR=1`** — defaults to skip because
  the transcript scan trips the macOS Sequoia/Tahoe "access data from other apps"
  prompt (Claude Code marks every transcript with the `com.apple.provenance`
  xattr). When opted out, the helper exits 0 with a `skipped` stdout line and
  leaves the artifact field absent; the renderer omits the line cleanly. See
  README §"Token counts" for the user-facing rationale and the FDA + env-var
  enable path.

The two are non-overlapping (sub-agent internal API calls vs. main-session turns).
Four separate orchestrator counters — fresh input / output / cache-read /
cache-creation — are preserved in the artifact because their $/token pricing
differs by roughly an order of magnitude, but only two (output + fresh input)
surface in the rendered PR-comment line: cache-read and cache-creation are
prompt-cache plumbing, not user-facing signal. All four remain in
`artifact.orchestrator_tokens` for offline cost analysis.

`/adamsreview:walkthrough` re-tallies both in §6.1 before §6.2's re-publish;
issue-filer agents dispatched in §6.5 (and the orchestrator turns that dispatch
them) land in the logs/transcript after the tally, so their cost surfaces on the
next lifecycle command's tally.

### Over-count modes (v1 accepted, opted-in only)

When `ADAMS_REVIEW_TALLY_ORCHESTRATOR=1` is set, the time-window filter
(`timestamp >= review_started_at`) counts every assistant turn in any transcript
under `~/.claude/projects/<cwd-slug>/`, regardless of whether it belongs to this
review. Clean cases: review → fix back-to-back; review → new review on the
updated codebase (each new review's `review_started_at` excludes the prior arc).
Over-count cases: any unrelated session or unrelated same-session chat in the
same cwd between `review_started_at` and the tally's invocation. Sub-agent tokens
are unaffected (their log is per-review-id, not cwd-wide). When opted out (the
default) there is no over-count *or* under-count from this filter — the field
stays absent and only any prior opted-in value survives. See
`bin/orchestrator-tokens.sh` header for the full caveat list;
`plans/orchestrator-tokens.md` §"Known limitations" for why the time-window
filter was accepted over a `SessionStart`-hook-based fix.

### Stale-data preservation across opt-in toggles

Skip on opt-out deliberately does not wipe a previously-written
`orchestrator_tokens` value. So an opted-in `/adamsreview:review` followed by
an opted-out `/adamsreview:fix` will publish the cumulative-cost line with the
review-time value, not a refreshed one — the rendered number can lag actual
spend. Re-opt-in on the next lifecycle command refreshes.
