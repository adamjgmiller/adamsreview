# 02 — Scanners (Multi-perspective detection)

This is the spec's most important and most modifiable document. The scanner layer is what this tool does differently from every "one agent reads the diff" code reviewer — and it's where most of the per-review token spend lives. Get this right.

## Core principle

> One AI scan misses bugs. Every scan misses bugs. The goal of the scan phase is to maximize the *union* of bugs caught by a portfolio of perspectives, then filter false positives downstream with the scoring gate + deep validation.

This document defines:

1. The **Scanner** interface (plugin contract).
2. The **portfolio** — which scanners run by default, and why.
3. **Axes of diversity** — the four dimensions along which perspectives vary.
4. **Repetition** — how the user dials up recall by running scanners multiple times.
5. **Corroboration / voting** — how multi-scanner agreement upgrades confidence.
6. **External scanners** — CodeRabbit, Codex, PR-scrape as first-class portfolio members.
7. **Adding a new scanner** — the modify-one-file extension point.

## Scanner interface

```ts
// src/scan/types.ts

export interface Scanner {
  /** Stable short id — used in prompts, token logs, voting. */
  id: string;                                                      // "careful-reader", "security-sweep", …

  /** Human label shown in reports and scanner selection UIs. */
  label: string;

  /** Model to dispatch. Scanner may override this with a user flag. */
  model: "haiku" | "sonnet" | "opus";

  /** Which impact types this scanner is allowed to emit. Used at merge-time for consistency
   *  and for scanner-selection filtering. A scanner that emits "security" but is listed
   *  as ["correctness"] is a bug in the scanner. */
  emits: Array<"correctness" | "security" | "ux" | "policy" | "architecture">;

  /** Return false to skip this scanner for this review (e.g. skip UX when !user_facing). */
  runWhen(ctx: ReviewCtx): boolean;

  /** Compose the prompt. MUST put the stable prefix (diff, CLAUDE.mds, manifest) at the
   *  top of the prompt, before scanner-specific instructions, so Anthropic prompt caching
   *  can hit across scanners. Orchestrator inserts a cache_control breakpoint between
   *  the prefix and the scanner-specific tail. */
  buildPrompt(ctx: ReviewCtx): Prompt;

  /** Parse the sub-agent's raw output into candidates. Return an empty array on total
   *  parse failure; the orchestrator logs the error and moves on. */
  parse(raw: string, ctx: ReviewCtx): Candidate[];
}

export interface Candidate {
  file: string;
  line_range: [number, number];
  claim: string;
  impact: "correctness" | "security" | "ux" | "policy" | "architecture";
  origin: "introduced" | "pre_existing" | "unknown";
  origin_confidence: "high" | "medium" | "low";
  scanner_confidence: "low" | "medium" | "high";                   // scanner's own estimate
  source: string;                                                  // scanner.id + optional replica tag
  evidence_snippet?: string;                                       // kept out of stored findings; used for dedup
}

export interface ReviewCtx {
  repo_root: string;
  reviewed_sha: string;
  comparison_ref: string;                                          // base ref for diff (may be origin/main)
  diff: string;                                                    // git diff comparison_ref..HEAD
  claude_mds: Array<{ path: string; body: string }>;
  reviewed_files_all: string[];
  user_facing: boolean;                                            // set by preflight classifier
  trivial_mode: boolean;
  repetition: Record<string, number>;                              // scanner id → replica count
  enrichments: Record<string, unknown>;                            // deterministic preflight data (e.g. "prior-fix-diff")
                                                                   // see 01-architecture.md § Preflight enrichment
}
```

## Scanner packaging (three files per scanner)

Each scanner is defined by three files that ship with the plugin:

1. **TS registry object** at `scripts/orchestrator/scan/scanners/<id>.ts` — implements the `Scanner` interface; owns `runWhen`, `buildPrompt`, `parse`.
2. **Prompt body** at `prompts/scanners/<id>.md` — the scanner-specific tail (role, bug-pattern list, return schema). Plain markdown with `{{mustache}}` placeholders.
3. **Agent file** at `agents/scanner-<id>.md` — frontmatter (`name`, `description`, `model`, `tools`) plus a short one-paragraph role preamble. The orchestrator references the agent by name when it emits `dispatch_agents` steps; Claude Code loads the agent file, applies the frontmatter, and executes the user message the orchestrator composed.

Example agent file:

```markdown
---
name: scanner-careful-reader
description: Deep structural + blast-radius reviewer. Traces callers, writers, parallel paths. Dispatched by /adams-review:review.
model: opus
tools: Read, Grep, Glob, Bash(git:*)
---

You are the careful-reader scanner. The orchestrator will hand you a diff plus the
surrounding codebase; your job is to find bugs a skilled human reviewer would catch —
the kind linters and tests miss but a careful read plus blast-radius tracing would
surface.

Over-flag. Downstream triage and validation handle precision.
```

Why the split: frontmatter (model, tools) is declarative plugin metadata that Claude Code reads directly; the TS object holds executable logic (prompt composition, parsing); the prompt markdown holds the body instructions, which are edited more often than the TS wrapper. Each file changes at a different cadence, so keeping them separate minimizes merge friction.

Two consequences of this packaging:

- **Scanners are invocable ad hoc.** Users can `@scanner-careful-reader <snippet>` from any Claude Code session for one-off analysis. `/agents` lists them with their descriptions.
- **Agent system prompt ≠ cached prefix.** The shared diff/CLAUDE.md/manifest prefix goes in the user message the orchestrator composes, with the `cache_control` breakpoint set there. Agent system prompts cache per-agent; only user-message content caches *across* agents. See `01-architecture.md § Prompt caching`.

## Registry

All scanners register into a single map. Adding a scanner = adding one import + one entry.

```ts
// src/scan/registry.ts

import { carefulReader } from "./scanners/careful-reader";
import { combinedSweep } from "./scanners/combined-sweep";
import { policyClaudeMd } from "./scanners/policy-claude-md";
import { uxBehavioral } from "./scanners/ux-behavioral";
import { diffLocal } from "./scanners/diff-local";
import { holistic } from "./scanners/holistic";

// External (opt-in via --ensemble)
import { coderabbit } from "./scanners/ext-coderabbit";
import { codex } from "./scanners/ext-codex";
import { prScrape } from "./scanners/ext-pr-scrape";

export const REGISTRY: Record<string, Scanner> = {
  "careful-reader": carefulReader,
  "combined-sweep": combinedSweep,
  "policy-claude-md": policyClaudeMd,
  "ux-behavioral": uxBehavioral,
  "diff-local": diffLocal,
  "holistic": holistic,
  "ext-coderabbit": coderabbit,
  "ext-codex": codex,
  "ext-pr-scrape": prScrape,
};

export const DEFAULT_MODE = "thorough";              // recall-first; see § Modes for the rationale

export const DEFAULTS = {
  quick: ["diff-local", "combined-sweep"],
  standard: ["careful-reader", "combined-sweep", "policy-claude-md", "ux-behavioral"],
  thorough: ["careful-reader", "combined-sweep", "policy-claude-md", "ux-behavioral",
             "diff-local", "holistic"],
  ensemble: ["careful-reader", "combined-sweep", "policy-claude-md", "ux-behavioral",
             "diff-local", "holistic",
             "ext-coderabbit", "ext-codex", "ext-pr-scrape"],
};
```

The user-facing flag `--mode` picks a preset (defaults to `thorough`); `--scanners` overrides with an explicit list; `--no-scanner` drops one from the picked preset. `standard` and `quick` are explicit cost-tier opt-ins for reviewers who want a cheaper pass.

## The four axes of diversity

The portfolio trades off recall, precision, and cost across four axes. Every scanner is a point in this 4-D space.

**Axis 1 — Prompt perspective.** Different scanners focus the model's attention on different bug classes:

- **Careful-reader** — unhurried, blast-radius-oriented. "Every function the diff adds/modifies: who calls it, who writes to it, what invariants does the surrounding code assume, are parallel paths consistent?" This is the highest-recall focused perspective and also the most expensive. Also walks the patterns surfaced by today's Stage 2.9 case study:
  - **Consumer-surface value trace** — for every column / field / API response / template variable / LLM tool output that the diff introduces or whose writer it modifies, walk from writer through storage to user-visible output. Flag when a writer's NULL/default can propagate to a surface that reads as honest (a real "0% APR" rate, a real "$0 balance," a real "Manual" classification) but actually represents missing data. AI-consumer surfaces (LLM tool schemas, prompt helpers, insight generators) are especially load-bearing because the model acts on `0%` as if it were a real rate.
  - **Cross-provider / domain-scope** — when a function runs inside a path named for one data source (`ray import-apple`, `syncPlaid`), check whether its queries and writes stay scoped to that source, or whether it silently re-evaluates unrelated data.
  - **SQL JOIN vs. UNIQUE-constraint cardinality** — for any JOIN the diff adds or modifies, check the join-key against the target table's UNIQUE constraint. An UPSERT with `ON CONFLICT(a, b)` permits multiple rows per `a`; a downstream `JOIN ... ON a.account_id = l.account_id` then fans out and downstream `SUM`/`COUNT` silently double-counts.
  - **Prior-fix reversion** — reads `ctx.enrichments["prior-fix-diff"]` (see `01-architecture.md § Preflight enrichment`); when non-empty, asks the model to judge whether the PR undoes a prior named fix.
- **Combined-sweep** — diff-local + security heuristics + comment/doc-contradiction check in one pass. "Flag off-by-ones, inverted conditions, silent-accept parsers, try/catch scope bugs, hand-rolled parser EOF invariants, sibling-validator strictness asymmetry, comment/code contradictions, injection / unsafe-eval / path-traversal heuristics."
- **Policy (CLAUDE.md)** — reads every CLAUDE.md in scope and flags rule violations. Cheap when CLAUDE.mds exist; skipped when they don't.
- **UX behavioral** — missing empty/loading/error states, silent failures, destructive-action confirmations, copy consistency, accessibility affordances. Also flags **diagnostic copy quality** on warnings/errors triggered by parsing, validation, or input rejection — does the message reveal the expected format ("Invalid date" vs "Expected MM/DD/YYYY"); does it name the specific value that failed; does it surface available context (file path, row, column) instead of generic "Something went wrong"? Only runs when `user_facing == true`.
- **Diff-local** — a cheap belt-and-braces pass. Small model, diff-only scope, over-flags mechanical issues a linter would miss (typos in identifiers, obviously-wrong literals, dead branches).
- **Holistic** — Opus, repo-wide, deliberately *unconstrained*. The "skeptical senior engineer who was just handed this PR" prompt with no checklist. Catches cross-layer bugs the focused scanners' narrower prompts don't reach: semantic correctness across layer boundaries, multi-failure-mode at the same call site, regressions of prior behavior, parallel paths whose invariants have diverged. Runs in `--mode thorough` and `--mode ensemble` only — it's the recall-first safety net that justifies thorough being the default mode.

**Axis 2 — Model.** Different models have different failure modes. Opus notices things Sonnet misses; Haiku catches obvious things an Opus with full context might over-think. The portfolio picks model per scanner, not uniformly.

**Axis 3 — Scope.** What the scanner is allowed to read. `diff-only` is cheapest but misses cross-file issues. `diff + neighbors` (Read access to files in the diff + adjacent) catches sibling-function bugs. `repo-wide` (full Read + Grep + git) catches cross-file blast-radius but is the most expensive. Scanner-specific.

**Axis 4 — Repetition.** Same scanner, different sampling seeds. N copies fan out in parallel; the merge phase dedups. Cheaper per-call than a new perspective, but lower marginal recall.

## Default portfolio (`--mode thorough`)

Designed to *match* today's ~1.48M-token spend while extracting more recall from it via repetition + voting + an unconstrained holistic safety net. **The "Projected tokens" column is extrapolated from the matching lens cost in the ray-finance baseline (see `00-overview.md § Baseline`), not measured against this scanner design.** Stage 12 (measurement + tuning) re-measures and updates.

| Scanner | Model | Scope | Replicas | Projected tokens | Role |
|---|---|---|---|---|---|
| **careful-reader** | opus | repo-wide | **2x** | ~520k | Deep structural + blast-radius. Repetition adds recall through corroboration voting. |
| **combined-sweep** | sonnet | diff + neighbors | **2x** | ~260k | Covers old L1 (diff-local), L4 (comments), L6 (security). 2x for recall. |
| **policy-claude-md** | sonnet | diff + CLAUDE.mds | 1x | ~50–80k | Covers old L3. Cheap when CLAUDE.mds are small. |
| **ux-behavioral** | sonnet | diff + CLAUDE.mds | 1x | ~100k, skipped if `!user_facing` | Covers old L5 + diagnostic copy quality. |
| **diff-local** | haiku | diff-only | 1x | ~40k | Cheap belt-and-braces; mechanical issues. |
| **holistic** | opus | repo-wide | 1x | ~200–260k | Unconstrained "senior reviewer" safety net. Stage 2.9's L7. |
| **Total** | | | | **~1.17M–1.26M** | vs. today's 677k Phase 1 (+74%–86%); thorough is **recall-first**, not budget-first |

With prompt caching hitting across the seven dispatches (the diff+CLAUDE.md prefix is byte-identical for every scanner including replicas), expected realized cost is **~1.0M–1.1M** for detection. With Triage (~80k) + Investigate (~440k) + Finalize (~30k), end-to-end thorough lands around **~1.5–1.6M tokens** — comparable to today's 1.48M but with significantly higher recall from the corroboration mechanism (≥2 scanners flagging same candidate → auto-graduate).

### Cheaper alternative: `--mode standard`

For reviewers who want the token-reduction win, `--mode standard` drops to four scanners (careful-reader, combined-sweep, policy-claude-md, ux-behavioral), 1x each, no holistic. Projected: ~440–570k for detection, ~900k end-to-end (−40% vs. today). See `00-overview.md § Targets` for the budget split.

### Why these specific consolidations

**`combined-sweep` merges L1+L4+L6.** Those three lenses today all Sonnet-scan the same diff with overlapping instructions. The output format is identical. Combining them in one prompt removes three diff-reads × ~95k = ~285k of duplicated context, at the cost of a slightly longer (but not 3× longer) output. Expected save: ~150–180k.

**`careful-reader` replaces L2.** Same Opus scanner, same repo-wide scope, same blast-radius instructions. Kept as-is — it's the heaviest hitter and the token budget is justified. In thorough mode it runs 2x; the second replica catches things the first misses through different sampling, and corroboration voting auto-graduates candidates that survive both runs.

**`policy-claude-md` replaces L3.** Separate because CLAUDE.md bodies aren't always in the cached prefix (they vary in size), and the rubric is distinct enough that combining with `combined-sweep` would dilute focus.

**`ux-behavioral` replaces L5.** Separate because UX reasoning is qualitatively different from bug-hunting and the skip condition (`!user_facing`) is non-trivial to factor out.

**`diff-local` is in thorough by default, also in `--quick`.** In `--mode standard` it's dropped (combined-sweep covers its ground); in thorough it's restored as cheap voting weight; in quick it's the only Haiku-tier presence.

**`holistic` is the recall-first safety net.** Lives in thorough and ensemble. Its prompt is deliberately *unconstrained* — no checklist, no bug-pattern enumeration, just "be a skeptical senior engineer." Catches the cross-layer bugs the focused scanners' narrower prompts don't reach (Stage 2.9's P2.4 / P2.8 class). Cost is real (~200–260k Opus) but the corroboration mechanism turns it into auto-graduation when it overlaps with `careful-reader`, which is the common case.

## Modes

```
--mode quick       2 scanners (diff-local + combined-sweep), all Sonnet/Haiku, no Opus.
                   Fast PR pass; useful for trivial diffs or when iterating.
--mode standard    4 scanners, 1x each, no holistic. Cost-tier opt-in (~900k tokens, -40% vs today).
                   Pick when you want the token-reduction win and accept lower recall.
--mode thorough    6 scanners (5 base + holistic) with 2x replicas on careful-reader and
                   combined-sweep. **Default mode.** Recall-first; ~1.5-1.6M tokens (parity
                   with today, but with corroboration voting + holistic safety net).
--mode ensemble    Thorough + 3 external scanners (CodeRabbit, Codex, PR-scrape).
                   Adds human-adjacent perspectives from outside the Anthropic model family;
                   requires external CLI auth/setup. ~1.8-2.3M tokens.
```

The `--mode` names are deliberately coarse. Fine control uses `--scanners` + `--repeat`:

```
/adams-review:review --scanners careful-reader,combined-sweep
/adams-review:review --mode standard --repeat careful-reader=2
/adams-review:review --mode standard --repeat careful-reader=2 --repeat combined-sweep=2
/adams-review:review --no-scanner ux-behavioral
```

## Repetition

Same scanner run N times with different sampling seeds. The orchestrator dispatches replicas as separate Agent tool-uses in the same parallel fan-out turn. Each replica's output goes into the candidate pool tagged `{scanner_id}#{replica}` in `source`.

Merge behavior:

- Candidates with (file, line_range overlap, claim fuzzy-match) from different replicas of the same scanner → merge into one candidate; union the source tags; retain the higher `scanner_confidence`.
- Candidates with (file, line_range overlap, claim fuzzy-match) from *different scanners* → merge into one candidate; union the source tags; retain the higher `scanner_confidence`; **mark as corroborated** (this drives the Triage auto-graduate rule).

Recommended repetition defaults by mode:

| Mode | careful-reader | combined-sweep | policy | ux | diff-local | holistic |
|---|---|---|---|---|---|---|
| quick | – | 1 | – | – | 1 | – |
| standard | 1 | 1 | 1 | 1* | – | – |
| thorough (default) | 2 | 2 | 1 | 1* | 1 | 1 |
| ensemble | 2 | 2 | 1 | 1* | 1 | 1 |

*only when `user_facing`

(Ensemble adds the three external scanners on top, each at 1x.)

Recall/cost curves should be measured empirically after the tool is running. The repetition knob is cheap to add (it's just a `for` loop) so it's available from day one.

## Corroboration / voting (auto-graduate)

When two *different* scanners flag the same candidate (post-merge), Triage auto-graduates it to `confidence: high` regardless of its own rubric score. This is today's "≥2 source families" rule, generalized.

Implementation: a candidate's `sources` field is the union of scanner ids that flagged it (replicas of the same scanner don't count as separate sources — `careful-reader#0` and `careful-reader#1` both tag as `careful-reader`). Triage checks `unique_scanners(candidate.sources).length >= 2` as an early path that skips the rubric prompt entirely.

Why auto-graduate is safe: the downstream Investigate phase still runs deep validation on every graduated candidate. Auto-graduation only decides *which candidates get the Opus read*, not *which are accepted as findings*. False-auto-graduates cost one Opus run each (~45k); missed auto-graduates cost a real bug.

## External scanners

External scanners have the same interface. They're dispatched via Bash (background shell) rather than Agent, but the orchestrator wraps them behind the same `Scanner` facade.

```ts
// src/scan/scanners/ext-coderabbit.ts

export const coderabbit: Scanner = {
  id: "ext-coderabbit",
  label: "CodeRabbit CLI",
  model: "sonnet",                                                 // for the normalizer pass
  emits: ["correctness", "security", "ux", "policy"],
  runWhen: ctx => ctx.external_enabled.coderabbit,

  async buildPrompt(ctx) {
    const rawOutput = await runCliInBackground("coderabbit", ["review", ...]);
    return {
      system: EXTERNAL_NORMALIZER_SYSTEM,
      user: `Normalize this CodeRabbit output into candidates:\n\n${rawOutput}`,
      cache_control: null,                                          // external outputs aren't cache-friendly
    };
  },

  parse(raw) { /* same Candidate[] return */ },
};
```

The orchestrator spawns the CLI, waits for output, then fires an inexpensive Sonnet "normalizer" agent that converts the CLI's prose into the Candidate schema. This merges today's Phase 1.5 adapter into the regular scanner dispatch.

Today's `PR-scrape` (read existing bot comments on the PR, filter for fresh ones, normalize) is also a `Scanner`. Orchestrator runs `gh api` to fetch comments; normalizer converts them.

## Prompt composition

Every scanner's prompt has the same outer shape, composed by the orchestrator:

```
[CACHED PREFIX — identical across scanners]

System: You are a code reviewer. ...
<diff>
{{ctx.diff}}
</diff>
<claude_mds>
{{ctx.claude_mds formatted}}
</claude_mds>
<manifest>
{{ctx.reviewed_files_all listed}}
</manifest>
[/CACHED PREFIX]

[Scanner-specific tail]
Task: {{scanner.buildPrompt(ctx).tail}}
Return: JSON array of Candidate matching this shape: {...}
```

The cached prefix is byte-identical across scanners, enabling Anthropic prompt caching to reduce input cost on the 2nd–Nth scanner call. Orchestrator inserts the `cache_control: { type: "ephemeral" }` breakpoint automatically.

## Merge and ID assignment

After all scanners return:

1. Collect all Candidate objects.
2. Fuzzy dedup: group candidates whose (file, line_range overlap ≥50%, claim Jaccard ≥0.5). Any group of size ≥2 from different scanners is corroborated.
3. Within each group, pick the richest representative (longest evidence_snippet, highest scanner_confidence), union the `sources`.
4. Assign monotonic ids `F001…F0NN`. Order by: (a) corroboration count desc, (b) scanner priority (careful-reader > combined-sweep > policy > ux > diff-local > holistic > ext-*), (c) insertion order. The merge function takes an optional `startFrom` parameter (default 1); the `/adams-review:add` verb passes `max(existing_ids) + 1` so new findings continue the sequence rather than colliding with F001.
5. Line-range sanity filter: drop candidates whose `line_range[1]` overshoots the file length at `reviewed_sha`. Log as scanner hallucination audit line.
6. Emit `candidate_added` events into the store.

This is today's `assign-finding-ids.sh` + `line-range-check.sh` + the jq builder, reimplemented in ~80 LoC of TypeScript.

## Origin classification

Origin (`introduced` vs `pre_existing`) is orthogonal to scanner output. After candidates are merged:

- Run `git blame` against each candidate's line range.
- If every line's blame sha is in `ancestor-of(comparison_ref)` → `origin: pre_existing`, `origin_confidence: high`.
- If at least one line's blame sha is in `comparison_ref..HEAD` → `origin: introduced`, `origin_confidence: high`.
- Mixed or unknown → `origin: unknown`, `origin_confidence: medium`.

This runs deterministically in TS (uses `git blame --porcelain`). Same logic as today's `origin-crosscheck.sh`, ~40 LoC.

`pre_existing + high` short-circuits downstream — those findings skip Triage scoring and go straight to the Finalize step as `report-only` entries (today's `pre_existing_report`). The user's walkthrough has a separate flow for filing GitHub issues on them.

## Prompt files

Prompt bodies are plugin-root assets (read at runtime from `${CLAUDE_PLUGIN_ROOT}/prompts/` by the orchestrator), not TypeScript source. Each scanner's scanner-specific tail lives at:

```
prompts/scanners/careful-reader.md
prompts/scanners/combined-sweep.md
prompts/scanners/policy-claude-md.md
prompts/scanners/ux-behavioral.md
prompts/scanners/diff-local.md
```

Plain markdown with `{{mustache}}` placeholders. The scanner's `buildPrompt` loads the file and fills in the placeholders. Modifying a scanner's instructions = editing one markdown file.

Shared fragments (like the Candidate schema description) live in `prompts/partials/`.

## Adding a new scanner

Three new files + one registry line:

1. `prompts/scanners/my-new-scanner.md` — the instruction body (plugin-root asset).
2. `src/scan/scanners/my-new-scanner.ts` — the Scanner object implementing `buildPrompt` + `parse` (TypeScript source; compiled into the shipped orchestrator).
3. `agents/scanner-my-new-scanner.md` — agent frontmatter (name, description, model, tools) + role preamble. This is what Claude Code dispatches when the orchestrator names the scanner.
4. `src/scan/registry.ts` — add one import + one map entry + (optionally) add it to a `DEFAULTS` mode preset.

Done. The pipeline, store, render, fix flow, and slash commands all pick it up automatically. No changes to state model, no schema migration, no disposition enum expansion.

## Scanner budget discipline

Each scanner documents its expected token cost per KB of diff + per CLAUDE.md at the top of its TS file:

```ts
// careful-reader.ts
/** @expectedTokens 2.5x diff + 0.5x CLAUDE.md (Opus, repo-wide) */
```

A per-review tokens-by-scanner table lands in the artifact so the user can see which scanners are over/under-budget. If careful-reader is consistently 2x its declared expectation on real reviews, that's a sign its prompt has drifted and needs pruning.

## Known open questions (hand these back to the user at build time)

Four questions the build plan deliberately defers until there's empirical data. Each one has a recommendation that's safe to start from; revisit after Stage 12 measurement.

1. Does repetition (same scanner 2x) deliver measurable recall gain over a single run? Requires empirical A/B on real PRs. **Recommendation**: ship with `--repeat` available; measure after 5–10 reviews; make the default x1 until data says otherwise.
2. Should external scanners (CodeRabbit, Codex) count toward corroboration voting? **Recommendation**: yes, but with lower weight — a careful-reader flag + a CodeRabbit flag corroborates; two CodeRabbit flags don't. Corroboration requires ≥2 distinct *internal* scanner ids OR 1 internal + 2 external.
3. Is `diff-local` useful as a default scanner, or only in modes? **Recommendation**: default-off, mode-on. Combined-sweep already covers its ground.
4. Should there be an auto-selected scanner portfolio based on PR size / language / user-facing detection? **Recommendation**: not in v1. Keep it predictable. Add `--mode auto` in v2 if data supports it.

## Checklist when editing this doc

- [ ] Any change to scanner defaults → update `DEFAULTS` in `02-scanners.md § Registry` AND the example code at `src/scan/registry.ts`.
- [ ] Any change to `Scanner` interface → update example in `02-scanners.md § Scanner interface` AND all scanner files.
- [ ] Any new scanner → add to the default-portfolio table AND the registry code block AND (if relevant) update expected-tokens math in `00-overview.md § Targets`.
- [ ] Any change to repetition defaults → update the per-mode table.
