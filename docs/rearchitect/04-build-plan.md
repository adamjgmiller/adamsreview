# 04 — Build Plan

Staged build plan for the AI agent building this tool. Each stage produces something testable, runnable, and verifiable. Later stages build on earlier ones. The plan is deliberately staged so the user can inspect progress between stages and inject changes.

Each stage has three sections: **scope** (what to build), **done-when** (acceptance criteria), and **verifiable output** (what the user can check).

This plan targets ~2–3 weeks of AI-agent work if run sequentially, or ~1 week of wall-clock if the user parallelizes some stages (e.g. Stage 5 can start while Stage 4 is being reviewed).

---

## Stage 0 — Foundation

### Scope

- Initialize an npm/pnpm project at the plugin root: `package.json`, `tsconfig.json`, `.gitignore`, `README.md`.
- Runtime dependencies (bundled into the shipped orchestrator): `zod`, `@octokit/rest`, `ulid`.
- Dev-only dependencies: `@anthropic-ai/sdk` (typed shapes + recorded-response tests), `typescript`, `vitest` (or Node's built-in test runner), `esbuild` (bundle TS → `scripts/orchestrator.mjs`), `eslint` + `@typescript-eslint/*`, `prettier`.
- Create the plugin directory tree at the repo root:

```
.claude-plugin/
└── plugin.json                (name, version, description, author)
commands/
├── review.md                  → /adams-review:review
├── walkthrough.md             → /adams-review:walkthrough
├── fix.md                     → /adams-review:fix
├── add.md                     → /adams-review:add
├── promote.md                 → /adams-review:promote
└── history.md                 → /adams-review:history
agents/
├── scanner-careful-reader.md
├── scanner-combined-sweep.md
├── scanner-policy-claude-md.md
├── scanner-ux-behavioral.md
├── scanner-diff-local.md
├── scanner-holistic.md
├── scanner-ext-coderabbit.md
├── scanner-ext-codex.md
├── scanner-ext-pr-scrape.md
├── triage.md
├── validator-deep.md
├── validator-light.md
├── fix-group.md
├── post-fix-reviewer.md
├── walkthrough-briefer.md
├── add-paste-normalizer.md    (verb-owned; not in scanner registry)
└── add-dedup.md               (verb-owned)
prompts/
├── scanners/                  (one <scanner-id>.md per scanner; includes holistic.md)
├── investigate.md
├── investigate-light.md
├── triage.md
├── fix-group.md
├── post-fix-review.md
├── walkthrough-briefing.md
├── add/                       (verb-owned prompt assets)
│   ├── paste-normalizer.md
│   └── dedup.md
└── partials/                  (candidate-schema.md, shared-context.md)
hooks/
└── hooks.json                 (SessionStart leftover-attempted warn; SessionEnd validate)
scripts/
└── orchestrator.mjs           (compiled ESM entrypoint; bundled from src/)
src/                           (TypeScript source; not loaded at runtime)
├── cli.ts                     (entry point: routes verb → handler)
├── orchestrate.ts             (the loop: plan → dispatch → apply; JSON-step protocol)
├── artifact/
│   ├── schema.ts              (Zod types)
│   ├── store.ts               (event append, view derivation)
│   ├── events.ts              (Event type union)
│   └── render.ts              (view → markdown)
├── preflight/
│   ├── index.ts
│   ├── branch.ts              (base/head detection, freshness)
│   ├── claude-md.ts
│   ├── user-facing.ts         (Haiku classifier)
│   └── enrichments/           (deterministic data feeds for scanner prompts)
│       ├── types.ts           (Enrichment interface)
│       ├── registry.ts
│       └── prior-fix-diff.ts  (git log -L over PR hunks; fix-intent regex)
├── scan/
│   ├── dispatch.ts
│   ├── registry.ts
│   ├── merge.ts               (dedup + id assignment + origin crosscheck)
│   └── scanners/              (one .ts per scanner; matches agents/ + prompts/scanners/)
├── triage/
│   └── index.ts               (dedup + scoring in one Sonnet call)
├── investigate/
│   ├── dispatch.ts
│   └── profiles.ts
├── fix/
│   ├── group.ts               (union-find on files_to_modify)
│   ├── dispatch.ts
│   ├── strategies/            (edit-agent-opus, eslint-autofix, etc.)
│   └── post-review.ts         (Opus verify/partial/regression classifier)
├── add/
│   ├── index.ts               (verb dispatcher)
│   ├── normalize.ts           (paste-mode Sonnet dispatch + structured-mode inline build)
│   └── dedup.ts               (Sonnet dedup against existing findings)
├── publish/
│   └── github.ts              (Octokit wrappers)
└── util/
    ├── exec.ts                (execFile wrapper; no shell)
    ├── blame.ts
    ├── paths.ts               (CLAUDE_PLUGIN_ROOT-aware)
    └── log.ts
test/
├── unit/                      (Zod, events, view derivation, merge, grouping)
├── fixtures/                  (events.jsonl → expected artifact + markdown)
└── integration/               (full pipeline against recorded Anthropic responses)
```

Notes on the split:

- `commands/`, `agents/`, `prompts/`, `hooks/`, `scripts/`, `.claude-plugin/` are **plugin-world assets** — Claude Code reads them directly at runtime via `${CLAUDE_PLUGIN_ROOT}`. They ship as-is.
- `src/` and `test/` are **build-time assets**. `src/` is TypeScript; `npm run build` bundles it via esbuild into `scripts/orchestrator.mjs`. `test/` doesn't ship.
- The plugin `package.json` has `"files"` restricted to the plugin-world directories + `scripts/orchestrator.mjs`, so published plugin artifacts don't carry source.

### Done-when

- `npm install` succeeds.
- `npm run build` produces `scripts/orchestrator.mjs` (single-file bundle).
- `node scripts/orchestrator.mjs --help` prints usage for all verbs and exits 0.
- `npm test` exits 0 (with no tests yet or a single trivial "hello" test).
- Project lints clean.
- `/plugin install /path/to/plugin` from a local Claude Code session registers every command in `commands/`.

### Verifiable output

```
$ node scripts/orchestrator.mjs --help
adams-review — multi-perspective code review pipeline

Usage: orchestrator.mjs <verb> [flags]

Verbs:
  review          Run a review end-to-end
  walkthrough     Interactive per-finding walk
  fix             Apply eligible fixes
  add             Inject externally-sourced findings into an existing review
  promote         Promote a finding manually
  history         List recent reviews

Run `orchestrator.mjs <verb> --help` for per-verb flags.
```

After `/plugin install`:

```
$ /adams-review:review --help
(slash command routes through the orchestrator and prints the same per-verb help)
```

---

## Stage 1 — Artifact store + event log

### Scope

- Implement `src/artifact/schema.ts` with the complete Zod model from `01-architecture.md § Data model`.
- Implement `src/artifact/events.ts` with the full Event union.
- Implement `src/artifact/store.ts`:
  - `new Store(reviewDir)` constructor.
  - `store.append(event)` — atomic append to `events.jsonl`.
  - `store.load()` — fold events into current `Artifact`.
  - `store.view()` — `Artifact` + derived per-finding sections.
- Implement `src/artifact/render.ts`: `View → string` (Markdown). Section ordering per `03-commands-and-ux.md § Output UX`.

### Done-when

- Round-trip test: construct a sequence of events, `append` each, `load()` returns an artifact that validates against the Zod schema.
- Derived view test: for each of the disposition-section mappings in `01-architecture.md`, a fixture event stream produces a finding in the expected section.
- Atomic append test: two parallel appenders never interleave mid-line. (Use `fs.appendFile` with `flag: "a"` — POSIX guarantees this under `PIPE_BUF`.)
- Render golden-fixture test: one hand-crafted event stream → compare rendered Markdown byte-for-byte against `test/fixtures/golden-report.md`.

### Verifiable output

```
$ npm test
  ✓ artifact/schema — round-trip (42 events)
  ✓ artifact/view — disposition mappings (11 cases)
  ✓ artifact/store — atomic append (100 concurrent writers)
  ✓ artifact/render — golden report byte-match
  All tests passed (4 / 4)
```

---

## Stage 2 — Orchestrator skeleton + slash commands

### Scope

- `src/cli.ts` routes verbs to handlers. Verb handlers are stubs that log "not implemented" and exit.
- `src/orchestrate.ts` implements the `plan → dispatch → apply` loop shell. No real work yet — it emits a hard-coded stub step (`{"step": 1, "next_step": "done", "reason": "stub pipeline"}`) and terminates.
- Every command file in `commands/` (`review.md`, `walkthrough.md`, `fix.md`, `add.md`, `promote.md`, `history.md`) gets the minimal loop-and-dispatch protocol (per `03-commands-and-ux.md § Commands`) with the verb hardcoded in the `node …/orchestrator.mjs <verb> $ARGUMENTS` line. `add.md` ships as a stub here; its orchestrator handler comes online in Stage 9.5.
- `.claude-plugin/plugin.json` with name `adams-review`, version `2.0.0`, author, description.
- `npm run build` bundles `src/` → `scripts/orchestrator.mjs`.

### Done-when

- `node scripts/orchestrator.mjs review --dry-run` emits the stub JSON on stdout.
- Slash command invocation in Claude Code (after `/plugin install /path/...`) runs the orchestrator and prints the stub output with no errors.
- The orchestrator loop protocol is documented at the top of `src/orchestrate.ts` and mirrored in `scripts/orchestrator/protocol.md`.

### Verifiable output

```
$ node scripts/orchestrator.mjs review --dry-run
{"step": 1, "next_step": "done", "reason": "stub pipeline"}

# After /plugin install in Claude Code:
$ /adams-review:review --dry-run
(orchestrator output rendered; no tool dispatches since next_step was "done")
```

---

## Stage 3 — Preflight (incl. enrichment)

### Scope

- Branch / base detection, dirty-tree gate, PR detection via `gh api`.
- Base-branch freshness reconciliation (today's §13.10 logic, ported to TS).
- CLAUDE.md discovery: walk up from every file in the diff, collect root-first deduped list.
- `reviewed_files_all` derivation from `git diff --name-only comparison_ref..HEAD`.
- User-facing Haiku classifier (one LLM call, dispatched as `next_step: "dispatch_agents"` with one entry).
- Trivial-diff early exit (set `trivial_mode: true` when diff is docs/config-only; user can override with `--full`).
- Prior-artifact detection via `latest.txt`; prompt the user if one exists.
- **Enrichment registry + dispatch.** Implement `Enrichment` interface (per `01-architecture.md § Preflight enrichment`). Build the first registered enrichment: `prior-fix-diff` (port of today's Stage 2.9 helper). Run all eligible enrichments in `Promise.all` after the Haiku classifier returns. Fail-soft per the contract: enrichment errors log + skip, never abort.
- Emit `review_started`, `preflight_classified`, and one `enrichment_returned` event per enrichment.

### Done-when

- On a PR with uncommitted changes, preflight aborts with the "working tree dirty" error block.
- On a PR with a stale local base branch, preflight dispatches the four-option AskUserQuestion (fast-forward / remote-ref / stale / abort).
- On a docs-only PR, `trivial_mode: true` flows into the Scan stage (which we'll use next stage to filter scanners) and enrichments are skipped.
- Running preflight against a real PR writes a new `rev_…` directory with `events.jsonl` containing `review_started` + `preflight_classified` + N `enrichment_returned` (N = enabled enrichments).
- `prior-fix-diff` enrichment exercised on the ray-finance `feat/import-apple` baseline: produces a non-empty suspects array including the `54de955` "Manual Accounts label regression" commit.

### Verifiable output

Run `/adams-review:review --dry-run` on a real PR in the review tool's own repo. The command:

- Creates `~/.adams-reviews/<slug>/<branch>/rev_01K.../`.
- Writes `events.jsonl` with `review_started` + `preflight_classified` + 1+ `enrichment_returned`.
- Prints a one-line summary: `Preflight complete: 12 files, 340 lines, 3 CLAUDE.mds, user_facing=false, trivial_mode=false, enrichments: prior-fix-diff(2 suspects).`

---

## Stage 4 — Scan stage (the core multi-perspective work)

### Scope

- Implement `Scanner` interface per `02-scanners.md`.
- Build the scanners that make up `--mode thorough` (the default). Each is three files (TS object + prompt md + agent md); see `02-scanners.md § Scanner packaging`:
  1. `careful-reader` (Opus, repo-wide) — port today's L2 prompt, consolidated. **Include the four Stage 2.9 patterns**: consumer-surface value trace, cross-provider/domain-scope, SQL JOIN vs. UNIQUE-constraint cardinality, prior-fix reversion (reads `ctx.enrichments["prior-fix-diff"]`).
  2. `combined-sweep` (Sonnet, diff + neighbors) — merge today's L1 + L4 + L6 into one prompt.
  3. `policy-claude-md` (Sonnet) — port today's L3 prompt.
  4. `ux-behavioral` (Sonnet) — port today's L5 prompt. **Include the Stage 2.9 diagnostic-copy-quality content** (warnings/errors that don't help users diagnose: missing expected format, generic "Something went wrong" where context was available).
  5. `diff-local` (Haiku, diff-only) — cheap belt-and-braces.
  6. `holistic` (Opus, repo-wide, deliberately unconstrained) — Stage 2.9's L7. Prompt is the "skeptical senior engineer who was just handed this PR" framing with no checklist; runs in `--mode thorough` and `--mode ensemble`.
- For each scanner, produce:
  - `src/scan/scanners/<id>.ts` — Scanner interface implementation.
  - `prompts/scanners/<id>.md` — prompt body with `{{mustache}}` placeholders.
  - `agents/scanner-<id>.md` — frontmatter (name, description, model, tools) + role preamble.
- Shared prompt partial for the Candidate schema at `prompts/partials/candidate-schema.md`.
- Implement `src/scan/dispatch.ts`: emit `next_step: "dispatch_agents"` JSON with one entry per `(scanner, replica)`, each carrying `subagent_type: "adams-review:scanner-<id>"` and an embedded user-message prompt.
- Implement `src/scan/merge.ts`: fuzzy dedup, ID assignment (with optional `startFrom` parameter for the add verb), origin crosscheck via `git blame`, line-range sanity filter. Emit `candidate_added` events.
- Prompt caching: shared prefix (diff + CLAUDE.mds + manifest) is byte-identical across scanners; orchestrator inserts `cache_control: { type: "ephemeral" }` at the prefix/tail boundary in the user message (not in the agent system prompt).
- Repetition: thorough mode fires careful-reader and combined-sweep at 2x replicas; `--repeat careful-reader=N` overrides per-mode default.

### Done-when

- Running scan in `--mode thorough` on the ray-finance `feat/import-apple` branch returns a pool of candidates that *includes* (a) the 29 today-baseline findings within ±20%, AND (b) at least three of the five Stage-2.9 "should" misses (P1.1 manual-account label, P1.2 NULL→0% APR, P2.5 cross-provider recat, P2.6 parseDate copy, P2.7 JOIN cardinality). The fourth and fifth landing is fine; missing more than two is a prompt-tune signal.
- Prompt-caching hit rate is measurable: the second+ scanner dispatches read `cache_read_input_tokens > 0` in the Anthropic API response. Log this in the token accounting.
- Thorough scan token cost lands at or below ~1.1M on the ray-finance baseline (after caching). Standard mode (`--mode standard`) lands at or below 500k.
- Scanner registry can be queried: `node scripts/orchestrator.mjs scanners --list` prints the active set with expected costs and per-mode replicas.
- Each scanner's agent file appears in `/agents` (Claude Code's agent listing) with its declared model and tool set.
- Holistic scanner's agent file inherits Read + Grep + Glob + `Bash(git:*)` — same broad surface as careful-reader, since its mandate is broad.

### Verifiable output

```
$ node scripts/orchestrator.mjs review --dry-run --mode thorough --base origin/main
Preflight complete: 20 files, 3284 lines, 6 CLAUDE.mds, user_facing=true,
                    trivial_mode=false, enrichments: prior-fix-diff(2 suspects).

Scan dispatching thorough portfolio:
  careful-reader   (opus,   repo-wide)        ×2
  combined-sweep   (sonnet, diff+neighbors)   ×2
  policy-claude-md (sonnet, diff+CLAUDE.mds)
  ux-behavioral    (sonnet, diff+CLAUDE.mds)
  diff-local       (haiku,  diff-only)
  holistic         (opus,   repo-wide, unconstrained)

  [progress as orchestrator fires Agent calls through slash command]

Scan complete: 47 candidates → 22 unique after dedup, 9 corroborated by ≥2 scanners
  Of 22 unique: 18 proceed to Triage, 4 short-circuit as pre_existing_report (origin gated, high confidence)
  Per scanner: careful-reader 17, combined-sweep 24, policy 5, ux 8, diff-local 4, holistic 11

Token summary (scan phase):
  Total:            1.06M
  Cached (prefix):  84k read at ~10% cost ≈ saved 76k
  Per scanner:      careful-reader×2 514k / combined-sweep×2 256k / policy 28k
                  / ux 96k / diff-local 38k / holistic 218k
```

---

## Stage 5 — Triage (dedup + scoring merged)

### Scope

- Implement `src/triage/index.ts`: one Sonnet dispatch that takes the candidate pool, returns:

  ```json
  {
    "merged_groups": [[id, id, id], [id], …],
    "scores": { "F001": {"confidence": "high", "rationale": "..."}, ... }
  }
  ```

- Shortcut: candidates corroborated by ≥2 distinct scanner ids auto-graduate to `confidence: high` without consulting the Sonnet output's score for them.
- Pre-existing high-confidence candidates short-circuit to `pre_existing_report` and skip scoring.
- Emit `candidates_merged` and `triage_scored` events.

### Done-when

- Against ray-finance baseline, Triage cost ≤85k tokens (vs today's Phase 2 + 3 = 88k).
- Same ~11 findings are below-gate as today, within ±2.
- Corroborated-skip path is exercised by at least one candidate in the baseline.

### Verifiable output

```
Triage complete: 18 candidates (pre_existing_report candidates short-circuited before Triage)
  Auto-graduated (corroborated): 5
  High confidence:               8
  Medium:                        3
  Low (below gate):              2

Token cost: 81k
```

---

## Stage 6 — Investigate

### Scope

- Implement `src/investigate/dispatch.ts`: for each confidence `medium` or `high` candidate, dispatch one agent with the appropriate model:
  - `correctness` or `security` → Opus, deep prompt (blast-radius, writers/consumers, parallel paths, fix proposal, verification context).
  - Everything else → Sonnet, light prompt (verify + actionability).
- Prompts in `prompts/investigate.md` and `prompts/investigate-light.md` (plugin-root assets).
- Parse the JSON response into `Investigation`; validate with Zod.
- Emit `investigation_returned` events.
- After every wave: run the tree-cleanliness sweep. Revert any dirty files and log an audit event.
- Optional Wave 2 (chain-retry): if any Wave 1 investigation returns `related_candidates_to_investigate`, dispatch a second wave of Scan → Triage → Investigate on those new candidates. Hard cap at 2 waves. Fold the related-candidates handling into the dispatch function (no separate orchestrator phase).

### Done-when

- Per-candidate Opus cost is within ±20% of today's ~45k average.
- Total Phase-4 cost at or below 500k on the ray-finance baseline (vs. 592k today; the 15% cut comes from not re-loading fragment context between dispatches).
- Wave 2 is exercised by at least one fixture test.
- Tree-cleanliness sweep is exercised by a fixture that deliberately dirties the tree from the investigator.

### Verifiable output

```
Investigate: 11 candidates (8 deep-lane Opus, 3 light-lane Sonnet)

  [parallel dispatch]

Investigate complete:
  Confirmed:    8 (7 auto-fixable, 1 manual)
  Uncertain:    1
  Disproven:    2

Token cost: 438k  (Opus: 402k / Sonnet: 36k)
```

---

## Stage 7 — Finalize

### Scope

- Implement `src/finalize/index.ts`: compute metrics (total tokens, elapsed, pr_size_buckets), render `artifact.md`, POST/PATCH the PR comment via Octokit, write `latest.txt`, emit `comment_published` + `review_finalized` events.
- The renderer derives sections from the view layer; no disposition enum lookups in the renderer.
- Related-findings grouping (today's Phase 5 cross-cutting) is done at render time: findings whose `Investigation.related_candidates_to_investigate` references another finding id get grouped in the rendered output with a `Related:` line.
- Pre-existing findings are rendered to a separate section with a per-finding "file issue?" hint (no actual issue filing at this stage — that's the walkthrough's job).

### Done-when

- End-to-end review against the ray-finance baseline produces an `artifact.md` that's content-equivalent to today's output (same finding ids, same sections, within rounding on metrics).
- PR comment POST/PATCH round-trips cleanly: first `/adams-review:review` POSTs; second `/adams-review:review` PATCHes the same comment.
- Running `/adams-review:review --mode thorough` (the default) end-to-end on a clean 20-file / 3k-line PR stays within the targets in `00-overview.md § Targets` — ≤35 min wall-clock, ≤1.6M tokens. A `--mode standard` run on the same PR lands at ≤25 min wall-clock and ≤900k tokens.

### Verifiable output

The rendered `artifact.md` plus the PR comment. The orchestrator prints the summary block from `03-commands-and-ux.md § Tokens & cost transparency`.

---

## Stage 8 — Walkthrough

### Scope

- Implement `src/walkthrough/index.ts`:
  - Compute skip set per `03-commands-and-ux.md § Walkthrough`.
  - AskUserQuestion for scope (Qualifying / Full).
  - Per-finding loop: dispatch briefing agent, AskUserQuestion for decision, apply the decision via events.
  - After the loop: re-render, re-publish, handle issue-filing for pre-existing findings.
  - Post a "Walkthrough decisions" comment with the full log.
- Briefing prompt in `prompts/walkthrough-briefing.md` (plugin-root asset). Matching agent file at `agents/walkthrough-briefer.md`.
- Decision events: `override_applied(kind: "promote" | "dismiss" | "reclassify")`. Reclassify lets the reviewer move a finding between impact buckets (e.g. ux → correctness) when the scanner/validator mis-categorized it.

### Done-when

- On the ray-finance baseline, walkthrough scope computes the same ~5 findings today's walkthrough covers.
- Per-finding UX matches what a reviewer expects: briefing → 3–5 options + recommendation → decision → move on.
- After walkthrough, the main PR comment reflects promoted findings as `confirmed_auto`.
- Decisions-log PR comment posts with correct counts.

### Verifiable output

Run `/adams-review:walkthrough` on a real PR. The flow completes interactively; artifacts and PR comments update correctly.

---

## Stage 9 — Fix

### Scope

- Implement `src/fix/group.ts`: union-find over eligible findings' `fix_proposal.files_to_modify`.
- Implement `src/fix/dispatch.ts`: one Opus agent per group, prompt instructs to use `Edit`/`Write` only, no git, no renames, no deletes. Collect `files_modified` + `files_created` + `per_finding_verification` back.
- Touched-file overlap guard (today's §Phase 9.pre): if two groups edited the same file, abort the fix run; emit `fix_attempted(outcome: null)` for all attempted findings. The derived view reads these as "attempted" — a `fix_attempts[]` entry with `outcome: null` and no matching `fix_classified` event — which blocks further fix runs until classification or explicit revert.
- Implement `src/fix/post-review.ts`: one Opus agent reviews the working-tree diff + attempted findings, returns per-finding `verified | partial | regression`.
- Revert regression groups; stage surviving-group files explicitly (by name, not `-A`); commit with a message that includes the per-finding outcome.
- Push in PR mode; emit `fix_classified` and (on successful commit) `fix_attempt` events with output_sha.
- Leftover-attempted hard abort: at the start of `/adams-review:fix`, if any finding has a `fix_attempted` event without a matching `fix_classified`, abort with the recovery message. The plugin's `SessionStart` hook already warns about this state on session load; this is the belt-and-braces check at fix-run start.

### Done-when

- Full fix loop completes on a PR with 5+ auto-fixable findings, producing one commit with the expected files staged.
- Regression revert path exercised by a fixture where post-review marks one group as regression — that group's files are restored to pre-fix state, surviving groups commit.
- Interrupt-mid-fix recovery path exercised: kill the process after `fix_attempted` event lands, re-run `/adams-review:fix`, see the hard-abort recovery message.

### Verifiable output

`git log` shows the fix commit with a message that carries Phase-9 truth. Artifact reflects `fix_attempts`. PR comment updates.

---

## Stage 9.5 — Add verb

### Scope

- Implement `commands/add.md` — slash-command trampoline; same protocol as the other verbs.
- Implement `src/add/index.ts`:
  - Parse arguments: paste mode (positional `$ARGUMENTS`), structured mode (`--file/--line/--claim`), mixed (paste + `--impact`), `--no-dedup`.
  - Locate artifact via `latest.txt`; refuse if no review exists for this branch.
  - Leftover-attempted gate (mirror Stage 9's recovery check).
- Implement `src/add/normalize.ts`:
  - Paste mode → dispatch one Sonnet sub-agent (`add-paste-normalizer`) with the paste body + `reviewed_files_all` context. Prompt at `prompts/add/paste-normalizer.md`.
  - Structured mode → build one candidate inline (no LLM call).
  - Both modes set `sources: ["external-add:<channel>"]`, `confidence: "high"` (auto-graduate; skips Triage), `origin: "introduced"`, `origin_confidence: "low"`.
- Implement `src/add/dedup.ts`:
  - Skip when `--no-dedup`.
  - One Sonnet sub-agent (`add-dedup`) compares new candidates vs. existing findings' (id, file, line_range, claim).
  - Match → drop new candidate; append the new source to the matched finding's `sources[]`.
- Reuse `src/scan/merge.ts` with `startFrom: max(existing_ids) + 1` to assign IDs.
- Reuse `src/investigate/dispatch.ts` lane-aware dispatch. **No Wave 2 chain retry.**
- Reuse `src/finalize/index.ts` for re-render + re-publish (PATCH the persisted `comment_id`).
- Emit events: one `candidate_externally_added` per new candidate, one `candidates_merged` per dedup match, one `investigation_returned` per validator, one `comment_published`.

### Done-when

- Paste mode: a hand-crafted three-bug paste produces 3 new findings with sequential IDs continuing past the highest existing F-id.
- Structured mode: `--file foo.ts --line 42 --claim "..."` produces one finding without invoking the normalizer.
- Mixed mode: paste + `--impact security` produces N findings all with `impact: "security"`.
- Dedup: a new candidate matching an existing finding does NOT create a new F-id; the existing finding's `sources[]` gains the new entry.
- Leftover-attempted gate: an artifact with a leftover `fix_attempted` event refuses with the recovery message.
- New findings flow through Investigate normally (deep Opus for correctness/security, Sonnet light for ux/policy/architecture); dispositions land per the standard scoring rubric.
- PR comment is PATCHed in place — no second PR comment posted.

### Verifiable output

```
$ /adams-review:add "F002 might be missing a null check on user.email at line 88. Also there's a race condition in cache invalidation in src/cache.ts around line 142 — two writers can both pass the staleness check before either commits."

Locating artifact... rev_01KPPT46J17C8M2SWWMS8D6SG8 (29 findings)
Leftover-attempted gate... clear
Normalizing paste... 2 candidates extracted by add-paste-normalizer (Sonnet, 4.1k tokens)
Dedup against 29 existing... 1 match (new#0 → F002, sources merged), 1 unmatched
Assigning IDs... starting from F030
Investigate... dispatching 1 Opus (correctness)

Added 1 new finding to rev_01K…:
  F030 confirmed_auto    correctness  src/cache.ts:142 — race in invalidation pre-commit window
Deduplicated 1 candidate against existing F002 (sources merged: external-add:paste).

Tokens: 67k total
Wall-clock: 2 min 14 sec
Report: <pr_comment_url>

Next: /adams-review:fix or /adams-review:walkthrough.
```

---

## Stage 10 — Promote, history, polish

### Scope

- Implement `/adams-review:promote <id>` — metadata mutation + re-render + re-publish.
- Implement `/adams-review:history` — walks `~/.adams-reviews/`, aggregates tokens + wall-clock per review, outputs table or JSON.
- `--dry-run` mode on every verb (preflight + scan + triage only, no investigate, no finalize publish).
- Error-as-prompt polish on every user-facing failure.
- Flag parsing is consistent across verbs (one shared parser).

### Done-when

- Every verb works end-to-end.
- `history --since 30d` on a test directory with three mock reviews produces expected table output.
- Error cases covered: invalid id, stale base, missing gh auth, Anthropic API failure, dirty tree.

### Verifiable output

```
$ /adams-review:history --since 30d --format table
BRANCH              REVIEW                     TOKENS   WALL    FINDINGS   FIXED
feat/import-apple   rev_01KPPT46J17C8M2SWW…    892k     22m     9           7
feat/import-apple   rev_01KPMBB6KR5P19N4WH…    1.01M    26m     8           5
main                rev_01KPH6ABQM67844RAA…    512k     14m     3           3
```

---

## Stage 11 — Migration and decommission

### Scope

- Write a migration subcommand: `node scripts/orchestrator.mjs migrate <old-review-dir>` that reads an old `artifact.json` + `phases.jsonl` + `tokens.jsonl` + `trace.md` and emits a fresh `events.jsonl` in the new shape. For branches with a currently-open review, the migration is optional — users can leave old reviews in place.
- Publish v2 to the user's Claude Code plugin marketplace (or install via path for local dev): `/plugin install <marketplace>/adams-review` or `/plugin install /path/to/adams-review-plugin`.
- Decommission the old shape: users `/plugin uninstall` the prior plugin (if installed that way) or run a one-line cleanup that removes the four old top-level command symlinks under `~/.claude/commands/` (`adams-review.md`, `adams-review-walkthrough.md`, `adams-review-fix.md`, `adams-review-promote.md`).
- Remove `docs/archive/` from the default read path (but keep the files available for reference); add a pointer note in the top-level README.

### Done-when

- Installing on a fresh machine via `/plugin install` yields only the namespaced verbs under `/adams-review:*`.
- Uninstalling via `/plugin uninstall adams-review` cleanly removes everything the plugin shipped.
- An old review directory's `artifact.json` can be read by `/adams-review:history` (directly, since the file still exists on disk); a migrated review directory's `events.jsonl` can be read by every verb that consumes the store.

### Verifiable output

```
# In Claude Code:
$ /plugin install /path/to/adams-review-plugin
Installed: adams-review 2.0.0
  commands, agents, and hooks registered per the plugin manifest

$ /adams-review:review --help
(prints the v2 review flags)

# On disk:
$ ls ~/.claude/commands/adams-review*    # symlinks from the old install — to be removed
(empty after manual cleanup or no-op if the user never used the old install)
```

---

## Stage 12 — Measurement + tuning (post-MVP)

### Scope

- Run `/adams-review:review` on 5–10 representative PRs across Adam's projects. Record tokens, wall-clock, findings, recall-vs-baseline.
- Compare against the matching old-pipeline reviews (the artifact history under `~/.adams-reviews/` holds the data).
- Tune:
  - Scanner-specific token budgets (per-kb-of-diff coefficients in each scanner's expectedTokens tag).
  - Default `--mode` selection logic.
  - Investigator prompt length (today's is large; trimming is safe if recall holds).

### Done-when

- Data exists to answer: "Does `--mode thorough` (default) catch more real bugs than `--mode standard` on real PRs, and by how much? Is the +60–70% token cost worth it?"
- Data exists to answer: "Does `--repeat careful-reader=2` (the thorough default) help vs. 1x?" Compare per-PR finding counts and unique-bug catches.
- Data exists to answer: "Does the holistic scanner earn its ~200–260k Opus cost? On the ray-finance baseline, does it surface P2.4 / P2.8 (the 'careful reader catches it' class)?" If holistic consistently flags bugs no other scanner caught, it stays. If not, demote it to `--mode ensemble` only.
- Data exists to answer: "Does `prior-fix-diff` enrichment surface real reversions, or mostly noise?" Track per-PR suspect counts and how often careful-reader confirms a reversion claim.
- Data exists to answer: "Does the `add` verb get used? When it does, what fraction of injected candidates land as `confirmed_auto`?" Low landing rate suggests pasted reviews are noisy; high rate validates external-add as a first-class workflow.
- Targets from `00-overview.md § Targets` are either met, or we have a specific reason they aren't.

---

## Stage ordering notes

- Stages 0–2 are strictly sequential.
- Stages 3 (Preflight + enrichment) can proceed in parallel with Stages 1 (Store) + 2 (Orchestrator skeleton + slash commands) once Stage 0 lands, but the events they emit need Stage 1's schema.
- Stage 4 (Scan) depends on Stages 1, 2, 3 (scanners read `ctx.enrichments`).
- Stage 5 (Triage) depends on Stage 4.
- Stage 6 (Investigate) depends on Stage 5 output (confidence scores).
- Stage 7 (Finalize) depends on Stages 3–6.
- Stage 8 (Walkthrough) depends on Stage 7 (an artifact must exist).
- Stage 9 (Fix) depends on Stage 6 (investigations with `fix_proposal`).
- **Stage 9.5 (Add)** depends on Stages 6 + 7 (reuses Investigate dispatch + Finalize); independent of Stages 8 + 9.
- Stages 10–11 depend on Stages 7–9.
- Stage 12 depends on everything.

Natural checkpoint reviews between stages (user inspects and adjusts): after 2, after 4, after 7, after 9, after 9.5, after 11.

## Test strategy per stage

Each stage adds its own tests to `test/unit/` and `test/fixtures/`. Golden-fixture tests (fixture in, expected output out) are preferred over mocks where possible.

End-to-end tests (under `test/integration/`) record Anthropic API responses on the first run and replay on subsequent runs — one run per major PR shape (small, medium, large; trivial; user-facing; with external scanners). The recorded-responses approach means tests run fast and deterministically and don't cost tokens per CI run.

## What NOT to build

- **No Python anywhere.** If an existing Python helper's logic is useful, port to TS.
- **No Bash scripts beyond the slash command trampoline + install/uninstall.** All helpers are TS.
- **No JSON Schema file.** Zod is the schema.
- **No separate `phases.jsonl` + `trace.md`.** One `events.jsonl`; derived views.
- **No `artifact-patch.py`-style canonical writer.** Store methods.
- **No prompt fragments inlined into the slash command via `!cat`.** Prompts live at the plugin-root `prompts/` asset directory; the orchestrator injects them into `Agent` tool-use calls via the dispatch-turn protocol.
- **No 11-disposition enum.** Derived view only.
- **No bash 3.2 compatibility concerns.** The orchestrator is compiled ESM loaded by Node; all helpers live in TypeScript.
- **No archive update.** `docs/archive/` is frozen. The new spec (this directory) is authoritative.

## Hooking in work-in-progress branches

Many extensions the user has on WIP branches are likely of one of these shapes:

- **A new scanner.** Drop into `src/scan/scanners/` + one prompt md + one agent md + one registry entry. See `05-extending.md § Adding a scanner`.
- **A new preflight enrichment** (deterministic data feed). Drop into `src/preflight/enrichments/` + registry entry. See `05-extending.md § Adding a preflight enrichment`. The Stage 2.9 `prior-fix-diff` helper landed via this extension point.
- **A new fix strategy.** Extension point in `src/fix/strategies/` with a shared `FixStrategy` interface. See `05-extending.md § Fix strategies`.
- **A new external tool integration.** External scanners are regular scanners; see `02-scanners.md § External scanners`.
- **A new report section.** Add to the renderer's section ordering. See `05-extending.md § Report sections`.
- **A new CLI flag or mode.** The flag parser is centralized; add to `src/cli.ts`.
- **A new way to inject candidates** (e.g. CI hook, Slack listener). The `/adams-review:add` verb owns paste + structured input today; future input sources would extend the verb. Out of v1 scope but the pattern is established.

Structure the build plan so every branch can be merged post-Stage-7 (when the scaffolding stabilizes). Each extension lands in its own PR, gets reviewed, and the WIP branch is re-based onto the new architecture.
