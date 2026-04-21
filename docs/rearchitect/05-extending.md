# 05 — Extending

How to plug work-in-progress branches (or entirely new ideas) into the rebuilt pipeline. Every extension point below is designed to be a single-file or two-file change with a single registry-entry line.

The design guarantee is: **if your change fits into an existing extension point, it doesn't touch the pipeline.** If it doesn't fit, this doc tells you where the closest extension point is and what to weigh when adding a new one.

## The extension point map

| You want to … | Extension point | Files touched |
|---|---|---|
| Add a new perspective / scanner | `src/scan/scanners/*.ts` + `prompts/scanners/*.md` + `agents/scanner-*.md` + registry | 3 new + 1 line |
| Add a new preflight enrichment (deterministic data feed for scanner prompts) | `src/preflight/enrichments/*.ts` + registry | 1 new + 1 line |
| Add a new fix strategy (e.g. non-edit based — `codemod run`) | `src/fix/strategies/*.ts` + registry | 2 files |
| Integrate a new external reviewer (e.g. Semgrep, CodeQL) | Scanner with external subprocess (TS + prompt + agent file) | 3 new + 1 line |
| Add a new output section to the report | `src/artifact/render.ts` + section config | 1 file |
| Add a new finding attribute (e.g. `cve_id`) | Zod schema + event | 2 files |
| Add a new investigation depth (e.g. "security-deep") | `src/investigate/profiles.ts` + `prompts/<profile>.md` + optional agent file | 2–3 files |
| Add a new slash-command verb (e.g. `/adams-review:stats`) | `commands/stats.md` + `src/cli.ts` + handler | 3 files |
| Add a new user-facing mode preset | `src/scan/registry.ts DEFAULTS` | 1 file |
| Add a new post-fix validator (e.g. "run tests after fix") | `src/fix/validators/*.ts` + registry | 2 files |
| Store extra metadata per review run | `src/artifact/schema.ts` + event | 2 files |
| Change the rendered output style | `prompts/render/*.md` partials | 1 file |
| Change a scanner's prompt | `prompts/scanners/*.md` | 1 file |

Each extension point below includes:
- The contract the extension must satisfy.
- A minimal working example.
- What the pipeline guarantees about calling the extension.
- What the extension is *not allowed* to do (to stay safe).

## Subprocess-safety note

Several extension examples below shell out to external tools (CLIs, linters, test runners). All subprocess invocations MUST use an `execFile`-style API that passes args as an array, not a shell string. This codebase provides a thin wrapper `src/util/exec.ts`:

```ts
// src/util/exec.ts

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function run(cmd: string, args: string[], opts?: { cwd?: string; timeout?: number }) {
  const { stdout, stderr } = await execFileAsync(cmd, args, {
    cwd: opts?.cwd,
    timeout: opts?.timeout ?? 60_000,
    maxBuffer: 50 * 1024 * 1024,
  });
  return { stdout, stderr };
}
```

Every extension that shells out imports and uses this wrapper. **Do not use `exec`, `execSync`, or a shell-templated command string** — those are command-injection-prone when interpolating user-controlled data (file paths, branch names, commit messages). Argument arrays side-step the shell entirely.

---

## Adding a scanner

Scanners are the most-likely extension. Each scanner is three files at three different levels of the plugin (TS source, prompt asset, agent declaration) plus one line in the registry.

### Contract

```ts
export interface Scanner {
  id: string;
  label: string;
  model: "haiku" | "sonnet" | "opus";
  emits: Array<"correctness" | "security" | "ux" | "policy" | "architecture">;
  runWhen(ctx: ReviewCtx): boolean;
  buildPrompt(ctx: ReviewCtx): Prompt;
  parse(raw: string, ctx: ReviewCtx): Candidate[];
}
```

### Example: a "test-coverage-gaps" scanner

**File 1 — `src/scan/scanners/test-coverage-gaps.ts`** (the Scanner object):

```ts
import { readFile } from "node:fs/promises";
import type { Scanner } from "../types";

const PROMPT_PATH = new URL(
  `file://${process.env.CLAUDE_PLUGIN_ROOT}/prompts/scanners/test-coverage-gaps.md`,
);
const PROMPT = await readFile(PROMPT_PATH, "utf-8");

export const testCoverageGaps: Scanner = {
  id: "test-coverage-gaps",
  label: "Test coverage gaps",
  model: "sonnet",
  emits: ["correctness"],

  runWhen(ctx) {
    return ctx.reviewed_files_all.some(f =>
      f.includes("/test/") || f.endsWith(".test.ts") || f.endsWith(".spec.ts")
    );
  },

  buildPrompt(ctx) {
    return {
      user: `${sharedPrefix(ctx)}\n\n${PROMPT}`,              // prefix first = cache-friendly
      cache_control: [{ type: "ephemeral", on: "prefix" }],
    };
  },

  parse(raw) {
    const json = extractJson(raw);
    if (!Array.isArray(json)) return [];
    return json.map(c => ({
      file: c.file,
      line_range: c.line_range,
      claim: c.claim,
      impact: "correctness",
      origin: "unknown",
      origin_confidence: "medium",
      scanner_confidence: c.confidence ?? "medium",
      source: "test-coverage-gaps",
    }));
  },
};
```

**File 2 — `prompts/scanners/test-coverage-gaps.md`** (the prompt body, plugin-root asset):

```markdown
You are the test-coverage-gaps scanner. The orchestrator has handed you a diff and
its surrounding CLAUDE.mds. Identify code paths added or modified by the diff that
lack test coverage and would plausibly hit a real bug if unchecked. ...

Return: JSON array of Candidate objects matching prompts/partials/candidate-schema.md.
Over-flag; downstream triage handles precision.
```

**File 3 — `agents/scanner-test-coverage-gaps.md`** (the agent declaration, plugin-root asset):

```markdown
---
name: scanner-test-coverage-gaps
description: Test-coverage-gaps scanner. Flags diff-introduced code paths without corresponding tests.
model: sonnet
tools: Read, Grep, Glob
---

You are the test-coverage-gaps scanner. The orchestrator will dispatch you with a
diff, surrounding CLAUDE.mds, and a list of test files already present. Return
Candidates for any untested path that could plausibly break.

Over-flag. Downstream validation filters false positives.
```

**Registry entry** — one import + one line in `src/scan/registry.ts`:

```ts
import { testCoverageGaps } from "./scanners/test-coverage-gaps";

export const REGISTRY: Record<string, Scanner> = {
  // ...existing...
  "test-coverage-gaps": testCoverageGaps,
};

// Optionally add to a mode preset:
export const DEFAULTS = {
  // ...
  thorough: ["careful-reader", "combined-sweep", "policy-claude-md", "ux-behavioral",
             "diff-local", "test-coverage-gaps"],             // ← add here
};
```

That's it. Pipeline runs it in parallel with other scanners; merge phase dedups against other scanner output; corroboration voting includes this scanner as a distinct source; render and slash commands need no changes.

### What your scanner must NOT do

- **Must not mutate the working tree.** Scanner agents are dispatched with read-only tool access. Don't ask the sub-agent to Write or Edit.
- **Must not fail silently.** Return `[]` on parse failure — the orchestrator logs the event as `scan_returned(error: "parse")`. Don't throw.
- **Must not require modifying the shared prefix.** The prefix (diff, CLAUDE.mds, manifest) is shared for caching. Scanner-specific context goes in the tail.
- **Must not exceed its declared emits.** A scanner with `emits: ["correctness"]` that emits `"security"` will fail merge validation.

### Prompt guidelines

Prompt files should be ~80–250 lines. If longer, your scanner is probably doing too much and should split. Each scanner's prompt must:

- State the role up front ("You are the X scanner. Your job is …").
- Describe the input shape (diff, CLAUDE.mds, etc.).
- List 3–10 concrete bug patterns to look for (not more; overstuffed prompts reduce recall).
- Demand the return JSON schema with an example.
- Close with "Over-flag; downstream filtering handles false positives."

---

## Adding a preflight enrichment

Enrichments are deterministic analyses that run between Preflight and Scan, producing structured data that scanners can opt into via `ctx.enrichments.<id>`. Good candidates: anything where a scripted analysis gives a cleaner answer than an LLM (git history walks, filesystem scans, dependency-graph traces).

### Contract

```ts
// src/preflight/enrichments/types.ts

export interface Enrichment<T = unknown> {
  id: string;                                                // "prior-fix-diff", "test-presence", …
  runWhen(ctx: PreflightCtx): boolean;                       // e.g. skip when trivial_mode
  run(ctx: PreflightCtx): Promise<T>;                        // deterministic; no LLM call
}
```

Rules (from `01-architecture.md § Preflight enrichment`):

- **Deterministic.** Same inputs produce same output. No LLM calls. Subprocess calls to `git`, filesystem reads, and local CLIs are fine.
- **Fast.** Soft cap: 10s total across all enrichments on a typical PR. Longer analyses (running a test suite) belong in a post-fix validator instead.
- **Fail-soft.** Throwing or timing out logs the error and skips; `ctx.enrichments.<id>` is absent. Scanners treat absence as "no data" — never as an abort.
- **Parallel.** Enrichments run in `Promise.all`. Ordering dependencies aren't supported in v1; chain inside one enrichment if needed.

### Example: a "test-presence" enrichment

Maps each changed file to whether a co-located test file exists. Lets scanners ask "did this change ship a test?" without re-deriving it every run.

```ts
// src/preflight/enrichments/test-presence.ts

import { access } from "node:fs/promises";
import type { Enrichment } from "./types";

type TestPresence = Record<string, { has_test: boolean; test_path: string | null }>;

export const testPresence: Enrichment<TestPresence> = {
  id: "test-presence",

  runWhen(ctx) {
    return !ctx.trivial_mode;
  },

  async run(ctx) {
    const out: TestPresence = {};
    for (const file of ctx.reviewed_files_all) {
      const candidates = deriveTestPaths(file);                // e.g. foo.ts → [foo.test.ts, __tests__/foo.test.ts]
      let hit: string | null = null;
      for (const c of candidates) {
        try { await access(`${ctx.repo_root}/${c}`); hit = c; break; }
        catch {}
      }
      out[file] = { has_test: hit !== null, test_path: hit };
    }
    return out;
  },
};

function deriveTestPaths(file: string): string[] {
  const base = file.replace(/\.(ts|tsx|js|jsx)$/, "");
  const ext = file.match(/\.(ts|tsx|js|jsx)$/)?.[1] ?? "ts";
  return [
    `${base}.test.${ext}`,
    `${base}.spec.${ext}`,
    file.replace(/\/([^/]+)\.(ts|tsx|js|jsx)$/, "/__tests__/$1.test.$2"),
  ];
}
```

Register:

```ts
// src/preflight/enrichments/registry.ts

import { priorFixDiff } from "./prior-fix-diff";
import { testPresence } from "./test-presence";
import type { Enrichment } from "./types";

export const ENRICHMENTS: Enrichment[] = [
  priorFixDiff,
  testPresence,                                              // ← new
];
```

A scanner that wants the data reads it in `buildPrompt`:

```ts
// src/scan/scanners/my-coverage-scanner.ts

buildPrompt(ctx) {
  const presence = ctx.enrichments["test-presence"] as TestPresence | undefined;
  const untested = presence
    ? Object.entries(presence).filter(([, v]) => !v.has_test).map(([f]) => f)
    : [];

  return {
    user: `${sharedPrefix(ctx)}\n\nFiles in the diff WITHOUT co-located tests:\n${untested.join("\n")}\n\n…`,
    cache_control: [{ type: "ephemeral", on: "prefix" }],
  };
}
```

### What your enrichment must NOT do

- **Must not call an LLM.** If you find yourself wanting to, it's a scanner, not an enrichment.
- **Must not exceed the 10s soft cap.** The review blocks on enrichments before Scan dispatches.
- **Must not mutate the working tree.** Read-only access to the repo and filesystem.
- **Must not fail hard.** Throwing is caught by the dispatcher; returning partial data with an internal `_errors` array is fine and preferred when some inputs succeed.

### What ships built-in

- **`prior-fix-diff`** — walks `git log -L` over every hunk in the PR's diff, filters commits by the fix-intent regex, verifies each suspect reachable from `comparison_ref`, produces a `PriorFixSuspect[]`. `careful-reader` consumes it and asks the model whether the PR undoes any suspect fix. Ported from today's Stage 2.9 plan.

Future ideas (not yet built):

- **`test-presence`** (above) — untested-file list.
- **`complexity-hotspots`** — cyclomatic complexity delta per file via tree-sitter.
- **`dependency-changes`** — structured summary of `package.json` / `pyproject.toml` / `go.mod` diffs.
- **`changelog-context`** — recent blame-adjacent context for every hunk; gives scanners "what was changed here last and why."

---

## Adding a fix strategy

Today, fix groups are always applied via Opus sub-agents editing with `Edit`/`Write`. In v2, we want a pluggable fix strategy layer so new approaches can slot in.

### Contract

```ts
export interface FixStrategy {
  id: string;
  label: string;
  appliesTo(finding: Finding): boolean;                      // whether this strategy is eligible for a given finding
  priority: number;                                          // higher = preferred when multiple strategies apply
  run(ctx: FixCtx, findings: Finding[]): Promise<FixResult>;
}

export interface FixResult {
  files_modified: string[];
  files_created: string[];
  per_finding: Record<string, { notes: string }>;
}
```

Built-in strategies:

- `edit-agent-opus` — today's default; one Opus agent per fix group.
- `codemod-jscodeshift` — for TS/JS refactors with a predictable pattern; run jscodeshift with a per-finding transform script.
- `eslint-autofix` — for findings whose claim matches an ESLint rule with `--fix`; just run `eslint --fix` on the file.

### Example: ESLint autofix strategy

```ts
// src/fix/strategies/eslint-autofix.ts

import { run } from "../../util/exec";
import type { FixStrategy } from "../types";

export const eslintAutofix: FixStrategy = {
  id: "eslint-autofix",
  label: "ESLint --fix",
  priority: 10,                                              // higher priority than edit-agent-opus

  appliesTo(finding) {
    return !!finding.claim.match(/^(ESLint: |eslint\()/);
  },

  async run(ctx, findings) {
    const files = [...new Set(findings.map(f => f.file))];
    await run("npx", ["eslint", "--fix", ...files], { cwd: ctx.repo_root });
    return {
      files_modified: files,
      files_created: [],
      per_finding: Object.fromEntries(findings.map(f => [f.id, { notes: "eslint --fix" }])),
    };
  },
};
```

Register:

```ts
// src/fix/registry.ts

import { editAgentOpus } from "./strategies/edit-agent-opus";
import { eslintAutofix } from "./strategies/eslint-autofix";

export const FIX_STRATEGIES: FixStrategy[] = [
  eslintAutofix,
  editAgentOpus,                                             // last resort
];

export function chooseStrategy(finding: Finding): FixStrategy {
  return FIX_STRATEGIES
    .filter(s => s.appliesTo(finding))
    .sort((a, b) => b.priority - a.priority)[0] ?? editAgentOpus;
}
```

The pipeline picks a strategy per finding; fix groups may now contain findings handled by different strategies. The group runner dispatches each strategy once, collects results, and hands off to the unified post-review.

---

## Integrating a new external reviewer

External reviewers are scanners with an async subprocess dispatch and a normalizer pass. The `ext-coderabbit.ts` and `ext-codex.ts` files are reference implementations. They follow the same three-file pattern as internal scanners (TS object + prompt body + agent file) plus one registry line.

Shape:

1. Scanner's `buildPrompt` spawns the CLI (via `util/exec.run`), captures output, returns a prompt that asks Sonnet to normalize the CLI's prose into `Candidate[]`.
2. Scanner's `parse` parses Sonnet's normalized JSON into the internal `Candidate` shape.
3. `runWhen` checks that the external tool is installed + authenticated.
4. If the external tool isn't ready, the orchestrator's preflight AskUserQuestion offers "proceed without it" or "stop and set it up."
5. The agent file frontmatter declares the normalizer's model (usually Sonnet) and the tool set needed to read the CLI's output (typically just `Read` — the subprocess runs in the orchestrator, not in the agent).

### Example: Semgrep

```ts
// src/scan/scanners/ext-semgrep.ts

import { run } from "../../util/exec";
import { which } from "../../util/which";
import type { Scanner } from "../types";

export const semgrep: Scanner = {
  id: "ext-semgrep",
  label: "Semgrep (static analysis)",
  model: "sonnet",
  emits: ["correctness", "security"],
  runWhen(ctx) {
    return ctx.external_enabled.semgrep && which("semgrep");
  },
  async buildPrompt(ctx) {
    const { stdout } = await run("semgrep", ["--config", "auto", "--json", ...ctx.diff_files], {
      cwd: ctx.repo_root,
    });
    return {
      system: EXTERNAL_NORMALIZER_SYSTEM,
      user: `Normalize this Semgrep JSON into candidates:\n\n${stdout}`,
      cache_control: null,                                   // no caching for external outputs
    };
  },
  parse(raw) { /* ... */ },
};
```

---

## Adding a report section

The renderer is a pure function of the view. Sections are ordered by a config:

```ts
// src/artifact/render-sections.ts

export const SECTIONS = [
  { id: "auto-fixable",    label: "Auto-fixable",               match: v => v.section === "confirmed_auto" },
  { id: "manual",          label: "Manual attention needed",    match: v => v.section === "confirmed_manual" },
  { id: "uncertain",       label: "Uncertain",                  match: v => v.section === "uncertain" },
  { id: "informational",   label: "Informational",              match: v => v.section === "confirmed_report" },
  { id: "pre-existing",    label: "Pre-existing",               match: v => v.section === "pre_existing_report" },
  { id: "below-gate",      label: "Below detection gate",       match: v => v.section === "below_gate", collapsed: true },
  { id: "disproven",       label: "Disproven",                  match: v => v.section === "disproven", collapsed: true },
  { id: "fix-results",     label: "Fix results",                match: v => v.fix_attempts.length > 0 },
];
```

Adding a section: add an entry with a `match` predicate and an optional custom renderer. Modifying a section: edit one entry.

---

## Adding a finding attribute

Say you want to add `cve_id` to each finding (for a "flag CVE matches" scanner to set).

1. Zod schema:

```ts
// src/artifact/schema.ts

const Finding = z.object({
  // ...existing fields...
  cve_id: z.string().nullable().default(null),
});
```

2. Event to set it:

```ts
// src/artifact/events.ts

type Event =
  | ...
  | { kind: "cve_associated"; finding_id: string; cve_id: string };
```

3. Fold handler:

```ts
// src/artifact/store.ts, inside the fold reducer

case "cve_associated":
  finding.cve_id = event.cve_id;
  break;
```

4. Renderer (if you want to show it):

```ts
// src/artifact/render.ts
if (finding.cve_id) {
  md += `\n**CVE**: ${finding.cve_id}\n`;
}
```

That's it. No migration needed for existing artifacts — `default(null)` means old event streams just produce `cve_id: null`.

---

## Adding an investigation profile

Different candidates may warrant different investigation depths. The dispatch picks a profile per candidate:

```ts
// src/investigate/profiles.ts

export const PROFILES = {
  "deep-correctness": {
    model: "opus",
    promptFile: "investigate.md",
    tools: ["Read", "Grep", "Bash(git:*)"],
    expectedTokens: 50000,
  },
  "deep-security": {
    model: "opus",
    promptFile: "investigate-security.md",
    tools: ["Read", "Grep", "Bash(git:*)", "Bash(gh:*)"],
    expectedTokens: 60000,
  },
  "light": {
    model: "sonnet",
    promptFile: "investigate-light.md",
    tools: ["Read"],
    expectedTokens: 15000,
  },
};

export function pickProfile(finding: Finding): keyof typeof PROFILES {
  if (finding.impact === "security") return "deep-security";
  if (finding.impact === "correctness") return "deep-correctness";
  return "light";
}
```

Adding a profile: add an entry + update `pickProfile` logic + write a prompt file.

---

## Adding a slash-command verb

Three things need to change in lockstep: the verb routes to a handler in the orchestrator, the handler lives alongside the other verbs, and a new slash-command file exposes it as `/adams-review:<verb>`.

```ts
// src/cli.ts

const verbs: Record<string, (args: string[]) => Promise<void>> = {
  review: runReview,
  walkthrough: runWalkthrough,
  fix: runFix,
  promote: runPromote,
  history: runHistory,
  stats: runStats,                                           // ← new
};
```

```ts
// src/verbs/stats.ts

export async function runStats(args: string[]) {
  // Parse flags, aggregate, print.
}
```

```markdown
# commands/stats.md → /adams-review:stats

---
description: Aggregate review statistics across runs.
argument-hint: "[--since 30d | --all] [--format table | json]"
allowed-tools: Bash(node:*), Read
---

Invoke the orchestrator:

    node "${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator.mjs" stats $ARGUMENTS

The orchestrator emits `next_step: "user_visible"` with the rendered stats block,
then `next_step: "done"`.
```

Update `--help`: `src/help.ts` lists verbs from the same registry.

---

## Adding a post-fix validator

Post-fix validators run between Phase 8 (apply fixes) and Phase 9 (classify outcomes). They're checks the orchestrator runs deterministically before asking the LLM to judge.

Built-in:
- `test-suite-runner` — runs `npm test` / `pnpm test` / `pytest` / `go test` depending on detected toolchain; if tests fail where they passed pre-fix, mark affected groups as regression candidates.
- `typecheck-runner` — runs `tsc --noEmit`; same logic.
- `lint-runner` — runs the project's linter; warns but doesn't force regression.

### Contract

```ts
export interface PostFixValidator {
  id: string;
  label: string;
  runWhen(ctx: FixCtx): boolean;                             // e.g. true only when tests exist
  run(ctx: FixCtx): Promise<PostFixValidation>;
}

export interface PostFixValidation {
  passed: boolean;
  details: string;
  regression_hints: Array<{ file: string; reason: string }>;
}
```

Runs after every fix group applies, before the LLM post-review. The LLM sees the validator results in its prompt and weights them into the verdict.

Registering: add to `src/fix/post-validators.ts`.

---

## Storing extra per-review metadata

If you want to store something at the review level (not per finding) — e.g. "which CI branch this review is for":

1. Schema:

```ts
const Artifact = z.object({
  // ...
  ci_ref: z.string().nullable().default(null),
});
```

2. Event:

```ts
type Event = ... | { kind: "ci_ref_set"; ci_ref: string };
```

3. Emit from whichever code knows the value:

```ts
await store.append({ kind: "ci_ref_set", ci_ref: process.env.CI_REF });
```

---

## Keeping extensions safe

Three rules for every extension:

1. **It must not directly edit `artifact.json` or `events.jsonl`.** Always go through the Store.
2. **It must not directly dispatch `Agent` tool-use.** Always return a `Prompt` object from the registered scanner / strategy / profile; the orchestrator handles dispatch.
3. **It must not assume its order in the pipeline.** Scanners run in parallel; fix strategies are picked per finding; post-fix validators run in registration order. If your extension has an ordering dependency, that's a bug.

## Extension-point stability guarantees

- **Scanner interface** — stable since Stage 4 of `04-build-plan.md`. Breaking changes require a major bump.
- **FixStrategy interface** — stable since Stage 9.
- **PostFixValidator interface** — stable since Stage 9.
- **Event types** — additive only. New event kinds are fine; renaming or removing requires a migration.
- **Zod schema** — additive only in patch/minor. Required fields can't be added without a migration.

## How to propose a change to an extension point

If you're about to add an extension and your change doesn't fit an existing point, stop and write a short proposal (one paragraph) in a new file under `docs/rearchitect/proposals/`. The proposal covers:

- The change.
- Which existing extension point is closest.
- Why the closest point isn't a fit.
- The new contract.
- Migration path for extensions using the old point (if applicable).

This creates a trail of extension decisions so future agents / future-you aren't surprised.
