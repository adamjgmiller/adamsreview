# 01 — Architecture

Pipeline shape, data model, orchestrator model, artifact store, event log. The "skeleton" that every other doc slots into.

## Pipeline shape

Each stage is a pure function from artifact + repo state to a set of events. Stages never mutate in place; they emit events that the store applies atomically.

```
Preflight  →  Scan  →  Triage  →  Investigate  →  Finalize
(det, incl.   (fan-out)  (gate)    (per-candidate)  (render + publish)
 enrichment)
                                                        ↓
                                                  (optional)
                                                  Fix  →  Verify  →  Commit
                                                  Add  →  Dedup  →  Investigate  →  Finalize
                                                          (skips Triage)
```

Compared to today's phased pipeline, the consolidations are:

- **Preflight** (~today's Phase 0, expanded): branch/PR detection, base-branch freshness, dirty-tree, claude-md discovery, trivial-diff check, user-facing Haiku classifier, and then deterministic **enrichments** (first built-in is `prior-fix-diff` — a git-history walk for regressions of prior named fixes). Enrichments produce structured data that scanner prompts opt into via `ctx.enrichments.<id>`. See `§ Preflight enrichment` below.
- **Scan** (~today's Phase 1 + 1.5 merged): multi-perspective candidate detection. External scanners (CodeRabbit/Codex/PR-scrape) are regular members of the scanner list, not a separate adapter. See `02-scanners.md`.
- **Triage** (~today's Phase 2 + Phase 3 merged): dedup + cheap scoring + gate, in one Sonnet agent. Single prompt that both groups near-duplicates and assigns a confidence tier to each surviving candidate. Cross-family agreement (same finding from ≥2 scanners) auto-graduates.
- **Investigate** (~today's Phase 4a + 4b merged): per-candidate deep validation. Deep-lane (correctness, security) gets Opus with blast-radius instructions; light-lane (policy, comments, ux) gets Sonnet with a lighter prompt. No separate phases — one dispatch function that picks the model per candidate.
- **Finalize** (~today's Phase 6 plus a pruned Phase 5): compute metrics, render `artifact.md`, post PR comment, write `latest.txt`. Cross-cutting clustering folds into the investigator's output (it names related findings in its return) and the renderer groups them at render time — no separate phase, no Opus agent.

Two optional secondary invocations reuse the same stages in different combinations:

- **Fix** (`/adams-review:fix`): loads an existing artifact, groups eligible findings, dispatches fix-group agents, post-fix review, revert regressions, commit + push.
- **Add** (`/adams-review:add`): loads an existing artifact, normalizes an externally-sourced paste (or takes structured flags) into candidates, dedups against existing findings, **skips Triage** (externally-sourced candidates auto-graduate — someone already paid the filtering cost), runs lane-aware Investigate, re-renders + re-publishes. See `§ Add flow` below.

Every merged phase saves a context-load + a per-phase token-logging block + a summary round-trip.

## Preflight enrichment

**Motivation.** Some of the highest-value signals for scanner prompts are cheap to compute deterministically and expensive to compute with an LLM. Example: "did this PR broaden a predicate in a way that reverts a prior commit whose message named a fix?" is a `git log -L` regex walk — no reasoning required. But making `careful-reader` re-derive it on every run wastes Opus tokens and isn't reliable.

Enrichments run at the tail of Preflight — after branch/diff detection and the user-facing classifier, before Scan dispatches. Each produces structured data, added to `ReviewCtx.enrichments.<name>`. Scanner `buildPrompt` implementations opt into the data they want.

### Enrichment contract

```ts
// src/preflight/enrichments/types.ts

export interface Enrichment<T = unknown> {
  id: string;                                         // "prior-fix-diff", "test-presence", …
  runWhen(ctx: PreflightCtx): boolean;                // e.g. skip when trivial_mode
  run(ctx: PreflightCtx): Promise<T>;                 // deterministic; no LLM call
}
```

Rules:

- **Deterministic.** Same inputs produce same output. No LLM calls. No API calls to anything that can give different answers on different days. Subprocess calls to `git`, filesystem reads, and local CLIs are fine.
- **Fast.** Soft cap: 10s total across all enrichments on a typical PR. Enrichments that need longer (e.g. running a test suite) belong in a different extension point (a post-fix validator, see `05-extending.md`).
- **Fail-soft.** An enrichment that throws or times out logs the error and is skipped; `ctx.enrichments.<id>` is absent. Scanners that depend on it treat absence as "no data" — never as an abort condition.
- **Parallel.** All enrichments run in `Promise.all`. Ordering dependencies between enrichments aren't supported in v1; if you need them, chain inside one enrichment's `run`.

### Built-in: `prior-fix-diff`

Walks `git log -L` over every hunk in the PR's diff, filters commits by fix-intent regex (`fix(es|ed)?|bug|regress(ion)?|revert|restore|correct|hotfix|patch`), checks each suspect reachable from `comparison_ref`, and produces a suspects list:

```ts
type PriorFixSuspect = {
  file: string;
  current_hunk_range: [number, number];
  prior_fix_commit_sha: string;
  prior_fix_commit_subject: string;
  prior_fix_commit_date: string;                      // ISO-8601
  prior_fix_touched_lines: number[];
};
```

`careful-reader.buildPrompt` reads `ctx.enrichments["prior-fix-diff"]` and, when non-empty, appends a prompt section asking the model to judge whether the PR reverts any suspect fix. Ported from today's Stage 2.9 plan (`plans/stage-2.9-missed-items.md`).

### Adding an enrichment

See `05-extending.md § Adding a preflight enrichment`. Extension cost: one TS file + one registry entry.

## Why merge dedup + scoring (Triage)

Today's Phase 2 dedup (30k tokens) and Phase 3 scoring (58k) are two Sonnet calls that each load the candidate list. A merged Triage call reads the list once, groups near-duplicates, and assigns confidence per surviving group — output is one JSON with both `groups` and per-group `confidence`. Expected savings: ~20–30k, plus one orchestrator round-trip.

Two auto-graduate rules let candidates skip the rubric prompt entirely:

1. **Corroboration shortcut.** When two scanners independently flag the same candidate (matching file + line proximity), Triage auto-graduates it to `confidence: high` regardless of its rubric score. This is today's "≥2 source families auto-graduate" rule.
2. **External-add bypass.** Candidates injected by `/adams-review:add` carry `confidence: high` from the verb itself and skip Triage entirely. The reasoning: a human bothered to escalate them, and deep Investigate is the right precision gate (not a Sonnet rubric). Mirrors today's review-add design — see `§ Add flow` below and `03-commands-and-ux.md § Add` (under `Interactive flows`).

## Data model

The artifact is one JSON object. Fields are flat where possible; nested only where grouping has semantic meaning.

```ts
// src/artifact/schema.ts — Zod source of truth

const Finding = z.object({
  id: z.string().regex(/^F\d+$/),                    // F001, F002, …

  // What was found
  file: z.string(),
  line_range: z.tuple([z.number(), z.number()]),
  claim: z.string(),

  // Routing (set by scanner, refined by triage/investigate)
  impact: z.enum(["correctness", "security", "ux", "policy", "architecture"]),
  origin: z.enum(["introduced", "pre_existing", "unknown"]),
  origin_confidence: z.enum(["high", "medium", "low"]),
  fixable: z.boolean(),                              // mechanical-fix feasibility

  // Provenance
  sources: z.array(z.string()),                      // scanner ids that flagged it
  blame_sha: z.string().nullable(),                  // earliest blame hit

  // Triage output
  confidence: z.enum(["low", "medium", "high"]).nullable(),
  confidence_rationale: z.string().nullable(),

  // Investigate output (nullable until investigate runs)
  investigation: Investigation.nullable(),

  // Fix lifecycle (empty until /adams-review:fix runs)
  fix_attempts: z.array(FixAttempt),

  // Human overrides
  human_override: HumanOverride.nullable(),

  // Grouping
  related_ids: z.array(z.string()),                  // investigator's cross-refs
});

const Investigation = z.object({
  verdict: z.enum(["confirmed", "disproven", "uncertain"]),
  score: z.number().min(0).max(100),                 // 0–100, for audit
  evidence: z.array(z.string()),
  blast_radius: z.object({
    writers: z.array(z.string()),
    consumers: z.array(z.string()),
    parallel_paths: z.array(z.string()),
    invariants: z.array(z.string()),
  }),
  fix_proposal: FixProposal.nullable(),              // null when not fixable
  verification: z.object({
    how_to_verify: z.array(z.string()),
    edge_cases: z.array(z.string()),
    what_breaks_if_incomplete: z.array(z.string()),
  }).nullable(),
});

const FixProposal = z.object({
  approach: z.string(),
  files_to_modify: z.array(z.object({
    file: z.string(),
    what: z.string(),
    why: z.string(),
  })),
});

const FixAttempt = z.object({
  run_id: z.string(),
  ts: z.string(),                                    // ISO-8601
  group_id: z.string(),
  input_sha: z.string(),
  output_sha: z.string().nullable(),                 // null on revert
  outcome: z.enum(["verified", "partial", "regression"]).nullable(),
  note: z.string().optional(),
});

const HumanOverride = z.object({
  reviewer: z.string(),
  ts: z.string(),
  kind: z.enum(["promote", "dismiss", "reclassify"]),
  reason: z.string(),
  hint: z.string().optional(),
});
```

**Why this shape vs. today's 11-disposition enum:**

Every "disposition" today is derivable from ≤3 fields:

| Today's disposition | Derivation from new fields |
|---|---|
| `below_gate` | `confidence == "low"` after Triage |
| `pending_validation` | `confidence != null && investigation == null` |
| `disproven` | `investigation.verdict == "disproven"` |
| `uncertain` | `investigation.verdict == "uncertain"` |
| `confirmed_auto` | `investigation.verdict == "confirmed" && fixable && origin == "introduced"` |
| `confirmed_manual` | `investigation.verdict == "confirmed" && !fixable` |
| `confirmed_report` | `investigation.impact in ("architecture","ux","policy") && !fixable` |
| `pre_existing_report` | `origin == "pre_existing" && origin_confidence == "high"` |
| `partial` | `last_fix_attempt.outcome == "partial"` |
| `regression` | `last_fix_attempt.outcome == "regression"` |
| `resolved` | `last_fix_attempt.outcome == "verified"` |

The renderer computes a `view` struct that exposes a `section` for each finding. The schema doesn't store "section" or "disposition"; those are views over the primitives. One place to change labels; no multi-write invariants to enforce.

## Event log

Every mutation is appended to `events.jsonl` alongside the artifact. The artifact is a *derived view* over events + some sticky metadata (review_id, reviewed_sha, base_branch, etc.).

Event types:

```ts
type Event =
  | { kind: "review_started"; review_id, reviewed_sha, base_branch, ... }
  | { kind: "preflight_classified"; user_facing, trivial, claude_mds }
  | { kind: "enrichment_returned"; enrichment_id, ok, elapsed_ms, payload_summary, error? }
  | { kind: "scan_dispatched"; scanner_id, model, replica }
  | { kind: "scan_returned"; scanner_id, replica, candidate_ids[], tokens, error? }
  | { kind: "candidate_added"; id, file, line_range, claim, impact, sources, ... }
  | { kind: "candidate_externally_added"; id, channel, sources, raw_input_length }
  | { kind: "candidates_merged"; keeper_id, merged_ids[] }
  | { kind: "triage_scored"; id, confidence, rationale }
  | { kind: "investigation_returned"; id, verdict, score, ... }
  | { kind: "override_applied"; id, kind, reason, reviewer }
  | { kind: "fix_attempted"; run_id, group_id, finding_ids[], input_sha }
  | { kind: "fix_classified"; finding_id, outcome, output_sha }
  | { kind: "comment_published"; comment_id, url }
  | { kind: "review_finalized"; total_tokens, elapsed_sec }
```

The store is append-only. `apply(events)` folds them into the current artifact shape. Interrupts and crashes are safe: the next run replays events up to the last complete one.

No transition whitelist is required — events only append, and derived dispositions are computed fresh on read. No "leftover attempted hard-abort" logic: if a `fix_attempted` event has no matching `fix_classified`, the next `/adams-review:fix` either classifies it (resumes) or emits `fix_classified(outcome: "regression")` (explicit revert). The plugin's `SessionStart` hook surfaces this state warning before the user tries to start a new fix run.

## Orchestrator model

The tool ships as a Claude Code plugin. Slash commands (one file per verb, under the plugin's `commands/` directory) are thin trampolines that shell into a compiled-TypeScript Node ESM script at `scripts/orchestrator.mjs` for every decision. The script emits structured JSON describing the next step; the slash command reads that JSON and dispatches `Agent`, `AskUserQuestion`, or prints to chat accordingly. The script never makes an outbound HTTP call — it is pure data folding plus subprocess helpers (`git`, `gh`).

Per-turn slash-command prompt surface: a short loop + dispatch-protocol fragment, constant across the whole review. Compare to today's aggregate fragment context (measured at ~4,600 lines in the current repo).

### Dispatch-turn protocol

The orchestrator emits one JSON object per step. Example:

```json
{
  "step": 3,
  "next_step": "dispatch_agents",
  "dispatches": [
    { "subagent_type": "adams-review:scanner-careful-reader", "prompt": "<embedded>", "replica": 0 },
    { "subagent_type": "adams-review:scanner-combined-sweep", "prompt": "<embedded>", "replica": 0 }
  ]
}
```

`subagent_type` uses the plugin-namespaced form `adams-review:<agent-name>` — that's the canonical id Claude Code exposes for plugin-bundled agents, and it's what the `Agent` tool-use block receives.

Slash command behavior per `next_step`:

- `dispatch_agents` — fire one `Agent` tool-use block per entry in `dispatches`, all in the same turn for parallelism. Then pipe the results back: `node "${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator.mjs" apply <results-json>`.
- `ask_user` — fire one `AskUserQuestion` with the provided options; pipe the answer back via `apply`.
- `user_visible` — print the provided block to chat; pipe an acknowledgment back.
- `done` — print the final summary; stop the loop.

The protocol shape is documented in `scripts/orchestrator/protocol.md` and kept stable across stages.

### Authentication and billing

All LLM calls happen via the slash command's `Agent` tool dispatches, which consume the user's Claude Code subscription (or API key, whichever Claude Code is configured with). The orchestrator script itself never reads `ANTHROPIC_API_KEY` and never calls the Anthropic API directly. That keeps billing unified, lets per-session effort-level settings flow through, and removes a configuration surface (the user never has to export a key to use the tool).

Dev-time tests that exercise scanner/investigator prompts against recorded responses do use `@anthropic-ai/sdk` and a fixture-replay layer — that dependency lives under `test/` only.

### Sub-agent prompts

Sub-agent prompts live in `prompts/*.md` at the plugin root (read by the orchestrator at runtime via `${CLAUDE_PLUGIN_ROOT}`) and are composed at call time by the TS orchestrator. The orchestrator embeds them in `Agent` tool-use blocks, interpolating the diff, CLAUDE.md contents, candidate details, etc. Prompt files are plain markdown with `{{mustache}}` placeholders — the orchestrator uses a tiny render function, no templating engine.

### Prompt caching

Anthropic's prompt caching offers two TTLs: 5-minute ephemeral (default) and 1-hour extended. **We use 5-minute ephemeral throughout.** Scanner fan-out and investigation dispatch both fire in a single orchestrator turn (parallel `Agent` tool-uses), so cache hits happen within seconds, not minutes. The 1-hour option doesn't buy us anything here and costs more per cached token.

The orchestrator composes every scanner prompt so that the *shared prefix* (system preamble + diff + CLAUDE.mds + repo manifest) is byte-identical across scanners. The cached prefix goes in the user message (not the agent's system prompt), because agent system prompts are per-agent — only user-message content caches *across* agents.

Expected savings: the diff is ~30–60k tokens for an average PR. If it's read once and cached, the 3–4 additional scanners reading the same prefix pay ~3–6k each instead of 30–60k. Net savings at today's Phase 1 volume: ~90–150k tokens per review.

**Caching is not free to implement** — the orchestrator must (a) structure every prompt with the cached portion first and `cache_control: {type: "ephemeral"}` on the breakpoint, and (b) ensure the wall-clock gap between first and last scanner dispatch is under 5 minutes. Today's pipeline already dispatches all scanners in one orchestrator turn (parallel fan-out), so (b) is already true.

## Artifact store

One directory per review: `~/.adams-reviews/<repo-slug>/<branch>/<review_id>/`

```
rev_01K…/
├── artifact.json           ← derived view over events (re-generated on each apply)
├── events.jsonl            ← append-only source of truth
├── artifact.md             ← rendered report
└── tokens.jsonl            ← per-sub-agent token accounting — projection over the event kinds that carry token counts (scan_returned, investigation_returned, fix_attempted), extracted for quick look-up
```

`trace.md` + `phases.jsonl` from today are absorbed into `events.jsonl`. One source of truth; anything today's split logs expose is a jq filter or a short Node one-liner over the event stream.

`latest.txt` at the branch level points to the most recent review_id — this matches today's convention.

## Store API

```ts
// src/artifact/store.ts

class Store {
  constructor(reviewDir: string) {}

  append(event: Event): void;                        // atomic append to events.jsonl
  load(): Artifact;                                  // fold events into current state
  view(): View;                                      // Artifact + derived per-finding sections
  render(): string;                                  // View → Markdown
  publish(): Promise<PublishResult>;                 // gh api POST/PATCH on PR
}
```

No schema-v1 wire format; Zod types are the single source. Migration story for existing on-disk artifacts (`latest.txt` + `artifact.json`) lives in `04-build-plan.md § Stage 11 — Migration and decommission`.

## Scanner dispatch (outline, details in `02-scanners.md`)

```ts
// src/scan/dispatch.ts

async function dispatch(ctx: ReviewCtx, registry: ScannerRegistry): Promise<Candidate[]> {
  const scanners = registry.selectFor(ctx);                         // filter by ctx (user_facing, trivial, etc.)
  const dispatches = scanners.flatMap(s =>
    Array.from({ length: ctx.repetition[s.id] ?? 1 }, (_, i) => ({
      scanner: s,
      replica: i,
      prompt: s.buildPrompt(ctx),                                   // stable prefix for caching
    }))
  );

  const results = await Promise.all(dispatches.map(runOne));        // fan out (slash command dispatches Agent in parallel)
  return mergeAndAssignIds(results);
}
```

## Investigation dispatch (outline)

```ts
// src/investigate/dispatch.ts

async function investigate(ctx, findings: Finding[]): Promise<InvestigationResult[]> {
  const enriched = await Promise.all(findings.map(f => {
    const model = chooseModel(f);                                   // opus for deep, sonnet for light
    return runAgent({
      model,
      prompt: buildInvestigationPrompt(ctx, f),
      tools: ["Read", "Grep", "Bash(git:*)"],
      readOnly: true,                                               // orchestrator checks tree cleanliness after
    });
  }));
  return enriched;
}
```

The read-only contract is enforced by the orchestrator: after investigate returns, `git status --porcelain` is clean. Any dirtying is reverted (this is today's Phase 4.4.5 sweep, kept as a safety rail).

## Fix flow (unchanged in spirit, simpler in code)

`/adams-review:fix` loads the artifact, selects eligible findings (`confidence == high && fixable && origin == introduced && !investigation.verdict == disproven` && no `human_override.kind == "dismiss"`), groups them by touched files (union-find on `fix_proposal.files_to_modify`), dispatches one Opus agent per group to edit the working tree, then dispatches one Opus post-fix review to classify each attempted finding as verified/partial/regression. Regression groups are reverted; surviving groups commit as one or N commits per `--granular-commits`.

The batch helpers (`--apply-fix-start`, `--apply-fix-outcomes`) in today's `artifact-patch.py` become two methods on `Store` that append the corresponding events. ~50 LoC each instead of hundreds.

## Add flow

`/adams-review:add` injects externally-sourced findings (an `/ultrareview` paste, an Opus once-over, a teammate's note, a CodeRabbit run outside `--ensemble`, a manual discovery) into the artifact already on disk for the current branch. The flow is a partial pipeline that reuses Investigate and Finalize but skips Triage:

```
Locate artifact → Leftover-attempted gate → Build candidates → Dedup → Assign IDs → Investigate → Finalize
```

Step details:

1. **Locate artifact.** Read `latest.txt` for the branch; load `events.jsonl`; refuse if no review exists ("run /adams-review:review first").
2. **Leftover-attempted gate.** Refuse if any finding has a `fix_attempted` event without a matching `fix_classified` (mirrors fix-start's safety rail). The plugin's `SessionStart` hook may have already surfaced this.
3. **Build candidates.** Two invocation shapes:
   - **Paste mode** (free-form `$ARGUMENTS`): one Sonnet "paste normalizer" sub-agent extracts candidates from prose. Deterministic repair: `file: null → "(unknown)"`, `line_range: null → [1,1]`.
   - **Structured mode** (`--file/--line/--claim`): skip the normalizer; build one candidate inline.
   - Both modes set `sources: ["external-add:<channel>"]` (`paste` or `cli`), `confidence: "high"` (auto-graduate; skips Triage), `origin: "introduced"`, `origin_confidence: "low"` (so the pre-existing override doesn't auto-fire from a paste alone — Investigate has to corroborate).
4. **Dedup.** One Sonnet sub-agent compares new candidates against existing findings. For each match: drop the new candidate; append the new source to the existing finding's `sources[]` (audit trail of "this issue was independently identified by another reviewer"). For each non-match: proceed.
5. **Assign IDs.** Continue the existing F-id sequence (`F<max+1>`, `F<max+2>`, …) — never restart at F001. The merge function takes a `startFrom` parameter that the add path supplies; the main scan path defaults to 1.
6. **Investigate.** Lane-aware dispatch identical to the main pipeline. **No Wave 2 chain retry** — the user is adding a small, bounded set; chain retries would expand scope unpredictably.
7. **Finalize.** Re-render `artifact.md`; PATCH the existing PR comment using the persisted `comment_id`; print a user-visible summary block.

Events emitted: `candidate_externally_added` (one per candidate from step 3), `candidates_merged` (one per dedup match), `investigation_returned` (one per validator result), `comment_published` (the PATCH).

What `/adams-review:add` deliberately doesn't do:

- **No re-run of Scan.** This is additive to the existing artifact, not a replacement. Run `/adams-review:review` for that (which overwrites).
- **No cross-cutting recompute.** Added findings don't retroactively join existing cross-cutting groups in the renderer. Documented small loss; if it becomes painful, a `--rerun-cross-cutting` flag can be added later.
- **No Triage scoring.** External candidates auto-graduate. See `§ Why merge dedup + scoring (Triage)` rule 2.
- **No working-tree mutation.** Validators are read-only; no fix-group execution; no clean-tree gate needed.
- **No persistence across fresh `/adams-review:review` runs.** A new review overwrites. Same property as promote.

## Error handling contract

- **Sub-agent JSON parse failure**: one retry with "return only JSON matching this shape" addendum. Second failure → drop candidate, append `scan_returned(error: "parse")` event, continue. Never abort the pipeline for one agent.
- **Tool failures** (`git`, `gh`): surface the stderr, retry once, escalate to user on second failure. Error-as-prompt format: `ERROR / CONTEXT / VALID INPUT / ACTION`.
- **Atomic writes**: `events.jsonl` uses `O_APPEND` (POSIX guarantees atomic appends under PIPE_BUF); `artifact.json` is written tmp+rename on each render. Same behavior as today.
- **Interrupts**: replay events; drop any incomplete trailing event (one that doesn't parse as JSON, which can happen on SIGKILL mid-write).

## Observability

One log (`events.jsonl`), three derived views:

- `artifact.json` — current state.
- `tokens.jsonl` — one entry per `scan_returned` / `investigation_returned` / `fix_attempted` event, extracted for quick inspection. Can be regenerated from `events.jsonl` via the orchestrator's `tokens` subcommand (`/adams-review:history --format tokens` or `node scripts/orchestrator.mjs tokens <review-id>`).
- `artifact.md` — rendered report.

The `/adams-review:history` verb (see `03-commands-and-ux.md`) aggregates tokens + wall-clock across every review under `~/.adams-reviews/`. Today this doesn't exist as a first-class operation; users grep tokens.jsonl across review directories.

## Tests

- **Unit**: Zod schema round-trips, event fold correctness, scanner prompt composition, view derivation. Vitest.
- **Integration**: golden fixtures of `events.jsonl` → `artifact.json` + `artifact.md`. 20–30 fixtures covering every disposition path and every scanner outcome.
- **End-to-end**: one smoke fixture that runs scan + triage + investigate + render against a mocked Anthropic API (recorded responses). Covers the orchestrator loop. No network calls.

Target: ≤60 assertions across all tests, vs today's 129. Fewer assertions because the state space is smaller.

## What this architecture explicitly preserves from today

- Multi-perspective scan fan-out (non-negotiable — see `02-scanners.md`)
- Cheap scoring gate (11:1 ROI shown by ray-finance data)
- Per-candidate deep Opus validation (the actual "reviewer work")
- Read-only validators with tree-cleanliness sweep
- Human-override bypass (`human_override`) for promote/dismiss/reclassify
- External-add bypass: human-escalated candidates skip Triage and go straight to Investigate (today's `/adams-review-add` design)
- Prior-fix reversion detection via deterministic `git log -L` (today's Stage 2.9 plan, formalized as the first preflight enrichment)
- Fix-group union-find over `files_to_modify`
- Post-fix review that classifies verified / partial / regression and reverts regression groups
- Append-only fix-attempt audit trail
- PR-comment POST/PATCH with stable HTML-comment marker
- Pre-existing-bug issue-filing flow

## What this architecture removes

- Phase 5 cross-cutting as a separate Opus call (fold into investigator output + renderer grouping)
- Phase 1.5 as a separate adapter (external scanners are regular scanners)
- Separate Phase 2 and Phase 3 (merged into Triage)
- The 11-disposition enum (derived view only)
- The state-transition whitelist (append-only events make it unnecessary)
- The `artifact-patch.py` Python module (Zod + Store methods)
- Fragment-per-phase markdown files (orchestrator is TS code)
- Bash 3.2 portability constraints (one TS runtime)
- `uv run --script` shebang dance (TS is compiled to ESM at build time and shipped in the plugin)
- `docs/archive/DESIGN.md` + `BUILD.md` as authoritative (commits carry rationale; this doc set is the spec)
