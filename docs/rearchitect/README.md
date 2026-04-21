# Re-architecture spec

Clean-slate specification for rebuilding `adams-review` as a TypeScript-compiled-to-Node Claude Code plugin with six namespaced slash commands, six default multi-perspective scanners (in `--mode thorough`, the default), deterministic preflight enrichments, and an event-logged artifact store.

## Reading order

The numbered docs are each self-contained. Read them in order for the full picture, or jump to the one that matches what you're changing:

1. **[00-overview.md](./00-overview.md)** — goals, non-goals, baseline token data from the ray-finance `feat/import-apple` review, numeric targets.
2. **[01-architecture.md](./01-architecture.md)** — pipeline stages, data model, orchestrator-in-code pattern, dispatch-turn protocol, event log, artifact store.
3. **[02-scanners.md](./02-scanners.md)** — multi-perspective scan phase (the heart of the design). Scanner interface, three-file packaging, portfolio, repetition, corroboration voting, external scanners. **Most important for future modifications.**
4. **[03-commands-and-ux.md](./03-commands-and-ux.md)** — six namespaced slash commands, flags, interactive walkthrough / fix / promote / add flows.
5. **[04-build-plan.md](./04-build-plan.md)** — staged build plan for the AI agent: 12 stages, each with done-when + verifiable output.
6. **[05-extending.md](./05-extending.md)** — plug-in points for work-in-progress branches. Scanner / preflight-enrichment / fix-strategy / external-tool / report-section / investigation-profile / slash-command verb.

## Authoritative sources

When two docs describe the same thing, these files own the source of truth:

| Concern | Owner |
|---|---|
| Command names + flags | `03-commands-and-ux.md` |
| Scanner ids, portfolio, modes, packaging pattern | `02-scanners.md` |
| Pipeline stages, data model, event types, store API, **preflight enrichment contract**, **add-flow auto-graduate rule**, **authentication and billing model** | `01-architecture.md` |
| Plugin directory layout, build + install flow | `04-build-plan.md § Stage 0` |
| Goals, non-goals, token/time targets per mode | `00-overview.md` |
| Extension contracts (Scanner, Enrichment, FixStrategy, PostFixValidator) | `05-extending.md` |

If an AI agent building from this spec encounters a conflict, defer to the owner. File a fix-up PR against the non-owner doc.

## How to modify this spec

Each doc is scoped so that most edits touch one file:

| If you're changing … | Edit |
|---|---|
| Goals, non-goals, or targets | `00-overview.md` |
| Pipeline stage count, data model, event types | `01-architecture.md` |
| Scanner portfolio, scanner interface, repetition model | `02-scanners.md` |
| Slash-command verbs, flags, UX flows | `03-commands-and-ux.md` |
| Build stages or acceptance criteria | `04-build-plan.md` |
| Extension points or extension contracts | `05-extending.md` |

Cross-references are explicit (e.g. `01-architecture.md § Data model`). When a change crosses documents — e.g. adding a new scanner type that changes the data model — update both, and add a line in this README noting the drift.

## Governance

- This spec is authoritative for the rebuild. `docs/archive/DESIGN.md` is the old design and is frozen; it should not be updated to reflect new decisions.
- Major changes (new pipeline stage, new data-model field, interface breaking changes) should land as a short `docs/rearchitect/proposals/<name>.md` first, reviewed, then rolled into the main docs.
- Minor changes (prompt tweaks, scanner reorderings, flag additions) go straight into the relevant doc.

## For the AI agent building from this spec

Before you start: read this README, then 00–05 in order. Hold the whole spec (~1,800 lines) in context before writing any code — each doc is self-contained but the cross-references matter.

Then start at `04-build-plan.md § Stage 0`. Work sequentially. After each stage, re-read the stage's "done-when" block and produce the "verifiable output." Commit at stage boundaries. Open a PR for user review at the checkpoints listed in `04-build-plan.md § Stage ordering notes`.

The existing codebase under `commands/`, `scripts/`, `test/`, and `docs/archive/` is available for reference — consult it when a behavior-equivalent port is easier than a from-scratch write (e.g. the `origin-crosscheck.sh` blame logic, or the `comment-freshness.sh` stale-comment filter). But do not translate prose-for-prose; simplify aggressively per the goals in `00-overview.md`.

When the spec conflicts with itself (it shouldn't, but drift happens), defer to the owner listed in `Authoritative sources` above and file a fix-up edit against the non-owner doc.

## Quick architectural summary (one-screen version)

- **One language**: TypeScript, compiled to Node ESM and bundled into the plugin at `scripts/orchestrator.mjs`. No Python, no Bun at runtime, no Bash helpers beyond the slash-command trampolines.
- **Distribution**: Claude Code plugin. `/plugin install adams-review` wires up six namespaced slash commands (`/adams-review:review`, `:walkthrough`, `:fix`, `:add`, `:promote`, `:history`) plus the scanner/validator agent files.
- **Orchestrator-in-code**: slash commands are ~40-line trampolines that shell into the bundled orchestrator. The orchestrator emits one JSON step per turn (dispatch_agents / ask_user / user_visible / done); the command reads it and dispatches Agent/AskUserQuestion accordingly. All LLM calls flow through Claude Code's subscription billing — the orchestrator never makes outbound HTTP calls and never reads `ANTHROPIC_API_KEY`.
- **Five pipeline stages**: Preflight (incl. deterministic enrichments) → Scan → Triage → Investigate → Finalize. Fix/verify/commit and Add are separate invocations.
- **Multi-perspective scanning** with 6 defaults in `--mode thorough` (`careful-reader` Opus + `combined-sweep` Sonnet at 2x replicas, `policy-claude-md` Sonnet, `ux-behavioral` Sonnet, `diff-local` Haiku, `holistic` Opus unconstrained). Each scanner is three files (TS object + prompt md + agent md). Optional cheaper tier (`--mode standard`) drops to 4 scanners 1x. Optional external scanners (CodeRabbit, Codex, PR-scrape) via `--mode ensemble`.
- **Preflight enrichments**: deterministic data feeds (no LLM calls) that scanners read from `ctx.enrichments`. First built-in is `prior-fix-diff` (git-history walk that surfaces prior named-fix commits the PR may revert).
- **Add verb**: `/adams-review:add` injects externally-sourced findings (paste, structured `--file/--line/--claim`) into the existing artifact. Skips Triage (auto-graduate); reuses Investigate + Finalize. PR comment PATCHes in place.
- **State machine**: 3 core fields (`confidence`, `origin`, `fixable`) drive a derived view. Gone: 11-disposition enum, state-transition whitelist, coupling invariants.
- **Artifact**: one `events.jsonl` (append-only source of truth) + derived `artifact.json` + rendered `artifact.md` + optional PR comment. No separate phases/tokens/trace files.
- **Prompt caching** on by default via Anthropic's `cache_control` (5-minute ephemeral). Shared prefix (diff + CLAUDE.mds + manifest) is byte-identical across scanners, placed in the user message so it caches *across* agents.

## Expected outcomes

Measured against the ray-finance `feat/import-apple` baseline (1.48M tokens, ~51 min wall-clock):

- **~40% token reduction** from consolidating overlapping Sonnet lenses + prompt caching + removing per-turn orchestrator context bloat.
- **~40% wall-clock reduction** from removing between-phase round-trips and trimming per-sub-agent prompt padding.
- **~75% code reduction**: ~14k lines → ~3k lines.
- **Multi-perspective still non-negotiable** — 6 default scanners in thorough (4 in standard), optional repetition, optional ensemble. The goal is recall.
- **Extensibility**: adding a scanner, preflight enrichment, fix strategy, report section, or slash-command verb is a single-file change (or a few for scanners; see `05-extending.md`).

See `00-overview.md § Targets` for the full numeric targets.
