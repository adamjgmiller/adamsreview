# Plan: Phase 1 parallel-dispatch — remove residual per-lens imperatives

**Status:** drafted 2026-05-03; awaiting validation by a fresh agent before
execution. Branch: `parallel` (this worktree).

**Pattern:** four small text edits in two files (one fragment + smoke) +
a patch version bump. No schema changes, no new commands, no helper
changes.

**One-line summary:** the parallel-dispatch directive added by `0466d04`
landed correctly but is being structurally overridden by 7 per-lens
imperative recipes immediately below it. Strip the imperatives, add a
single closing dispatch step, fix the §1.2.1 contradiction, harden the
smoke guard.

---

## Context

### The original regression (PR #23)

PR #23 (squash-merged as `9e3df42`) extracted L1–L7 lens prompt bodies
into `fragments/lens-prompts/` so `/adamsreview:codex-review` could
share them. That refactor (commit `1c08ac3` on the `codex-review`
branch, before squash) replaced the inline blockquoted L1–L7 prompts in
`fragments/01-detection.md` §1.3 with per-lens "Read
`fragments/lens-prompts/L<N>.md` … and dispatch" recipes — 7 of them in
a row.

Per-lens recipes structurally read top-to-bottom as a sequence of
self-contained "Read X then dispatch Agent" pairs. The orchestrator,
processing the fragment as instructions, executed them as 7 separate
turns instead of a single batched dispatch turn. Phase 1 wall-clock
went from `max(lens_durations)` to `sum(lens_durations)` and the
ensemble fan-out lost its overlap window with lens dispatches.

### The "fix" that landed but isn't holding (commit `0466d04`)

Before squash-merge, the `codex-review` branch carried `0466d04` "Fix
Phase 1 serial-dispatch regression from lens-prompt extraction." The
commit added an 18-line emphatic directive at the top of §1.3
(`fragments/01-detection.md:298–314`) starting with "**Parallel
dispatch — load-bearing.**" plus smoke assertion `CR-12`
(`test/smoke.sh:5610–5637`) guarding the directive's presence.

Both are live in the squash-merge tree and on `parallel`/`main` today
(`grep -n 'Parallel dispatch — load-bearing' fragments/01-detection.md`
returns line 298). Smoke passes 312 assertions including CR-12.

**It still doesn't hold.** User reproduced the same serial-dispatch
behavior on a worktree of `beta-briefing/onboard-page` running
`/adamsreview:review` — all lenses ran serially across multiple turns
despite the directive being present.

### Root cause: textual directive vs. structural ambiguity

The directive's prose is fine. What's breaking it is structural:

1. **`fragments/01-detection.md` §1.3 has 7 per-lens subsections
   (lines 316–395)**, one each for L1 through L7. Each subsection
   contains TWO imperative phrases:

   - "Launch one `Agent` tool-use with `model: X`, `subagent_type:
     general-purpose`."
   - "Read `fragments/lens-prompts/L<N>.md` ... Prepend the shared
     invariants from step 1.2.1 **and dispatch**."

   `grep -c` confirms 11 imperative phrases across the 7 subsections
   ("Launch one \`Agent\` tool-use" appears 7 times; "and dispatch"
   appears 4 more times in the L<N>.md "Prompt body" recipe lines).

2. **§1.2.1 line 92 contradicts the §1.3 top directive.** It says:

   > "The lens-body files (`fragments/lens-prompts/L<N>.md`) are read
   > at each lens's dispatch step (1.3)."

   That's "read per-lens at dispatch time" — directly opposite the
   §1.3 top directive's "Read all applicable L<N>.md files first
   (these `Read` tool-uses can run in parallel within one
   orchestrator turn). Then issue EVERY applicable lens's `Agent`
   tool-use in a SINGLE orchestrator turn."

3. **Smoke CR-12 only guards directive presence, not the absence of
   competing imperatives.** It greps for "SINGLE orchestrator turn"
   inside the §1.3 window between the section header and the first
   `#### L1` subsection. Anything inside the per-lens subsections is
   outside the window.

An orchestrator processing the fragment top-to-bottom sees: top
warning → L1 imperatives ("Launch... read... and dispatch") → execute
→ L2 imperatives → execute → ... 6 more turns. Local imperatives beat
distant warnings.

### Why `/adamsreview:codex-review` doesn't have this bug

`fragments/01-codex-detection.md` §1.3 (lines 186–205) is structurally
robust: ONE recipe with `L${N}` template substitution, no per-lens
subsections. Cannot be misread as serial because there's nothing
serial-shaped to follow. (The `:codex-review` path's per-lens
specifics live in §1.2c which builds prompt files for all running
lenses before §1.3.)

### Why `:review --ensemble` is what reproduced the bug

The user said "L1–L7 agent serially." Under default `:review`, only L1–L6
run; L7 is `--ensemble`-gated. So they ran `:review --ensemble` on the
`onboard-page` PR. Both modes are affected (`:review` default also
hits this with L1–L6); `--ensemble` just makes the symptom 7-wide and
more obviously wrong.

`/adamsreview:codex-review` is **not** affected by this bug — that
path's parallelism is structurally clean per the section above.

---

## Goal

Phase 1 of `/adamsreview:review` (default and `--ensemble`) dispatches
all applicable lens `Agent` tool-uses in a SINGLE orchestrator turn,
robustly against future fragment edits.

**Done when:**

1. `fragments/01-detection.md` §1.3 per-lens subsections (L1 through
   L7) contain ZERO imperative dispatch phrases. Each is a declarative
   spec (model, permissions if any, prompt body location, per-lens
   substitutions). No "Launch", no "and dispatch", no "Read X" recipe.
2. A new closing `#### Dispatch turn` subsection sits between L7 and
   "Ensemble fan-out" — single, unambiguous action target.
3. §1.2.1's "are read at each lens's dispatch step" line is corrected
   to describe the bulk pre-read.
4. Smoke `CR-12` is split into `CR-12a` (existing presence check) and
   a new `CR-12b` that fails if any imperative dispatch phrase appears
   in the per-lens subsections.
5. Smoke total: 312 → 313 (one new assertion).
6. Plugin version bumped `0.3.1 → 0.3.2` (patch bump per CLAUDE.md
   release discipline — this is a bug-class behavior correction, not a
   docs-only change).

---

## Non-goals / explicitly deferred

- **No restructure of §1.3 into a dispatch matrix / table.** Considered
  and rejected as too invasive — would lose the per-lens reading-scope
  notes (L2 reads surrounding files, L7 reads diff broadly, etc.) that
  currently sit in prose form in each subsection.
- **No changes to `01-codex-detection.md`.** The codex-review path is
  already structurally robust against this bug class.
- **No changes to lens-prompt files** (`fragments/lens-prompts/*.md`).
  The contents are fine; only the dispatching prose around them is
  ambiguous.
- **No CLAUDE.md edit.** The pipeline-shape diagram still accurately
  describes Phase 1 as parallel; no doc drift to fix.
- **No fragment-level helper changes.** This is a prose hardening, not
  a tool-contract change. `artifact-patch.py`, `assign-finding-ids.sh`,
  etc. are untouched.

---

## Validation steps for the fresh executing agent

Before making any edits, verify the diagnosis matches the codebase.
The fresh agent should:

1. Run `git log --oneline -5 main` and confirm `9e3df42` is HEAD —
   confirms the squash-merge of PR #23 is what's live.
2. Run `git log --all --oneline | grep -i 'serial\|parallel'` and
   confirm `0466d04` "Fix Phase 1 serial-dispatch regression from
   lens-prompt extraction" is reachable from `codex-review` only (not
   from `main`/`parallel`) — confirms the fix's content survived the
   squash-merge but not the commit.
3. `grep -n 'Parallel dispatch — load-bearing' fragments/01-detection.md`
   — must return line 298. Confirms the directive content landed.
4. `grep -nc 'Launch one \`Agent\` tool-use\|and dispatch'
   fragments/01-detection.md` — must return 11. Confirms the
   competing imperatives are still in place.
5. `test/smoke.sh` — must pass 312/312. Confirms baseline before edits.
6. Read `fragments/01-detection.md` lines 58–100 (covers §1.2.1
   including the contradicting line 92).
7. Read `fragments/01-detection.md` lines 296–425 (covers §1.3 in
   full including all per-lens subsections and the Ensemble fan-out
   subsection).
8. Read `fragments/01-codex-detection.md` lines 186–205 (the
   structurally-clean sibling pattern, for comparison).
9. Read `test/smoke.sh` lines 5605–5637 (the existing CR-12 guard).

If any of steps 1–5 disagrees with the diagnosis above, **stop and
report** instead of executing. Otherwise proceed to "Changes."

---

## Changes

### Change 1: De-imperativize the 7 per-lens subsections

**File:** `fragments/01-detection.md`

Each `#### L<N>` subsection currently follows the pattern:

```
#### L<N> — <name> (<Model>)

Launch one `Agent` tool-use with `model: <model>`, `subagent_type: general-purpose`.

[optional permissions/scope notes]

Prompt body: Read `fragments/lens-prompts/L<N>.md` — its content is the L<N>
prompt body verbatim. [optional substitution clauses] Prepend the shared
invariants from step 1.2.1 and dispatch.
```

Convert each to declarative spec form:

```
#### L<N> — <name> (<Model>)

Dispatch spec: `model: <model>`, `subagent_type: general-purpose`.

[optional permissions/scope notes — unchanged]

Prompt body: `fragments/lens-prompts/L<N>.md` (read in step 1.3's bulk
pre-read; its content is the L<N> prompt body verbatim).
[optional substitution clauses, rephrased declaratively]
Final prompt = shared invariants (from step 1.2.1) + lens body.
```

Two surgical text changes per subsection:
- "Launch one `Agent` tool-use with" → "Dispatch spec:"
- "Read `fragments/lens-prompts/L<N>.md` — its content is the L<N>
  prompt body verbatim. ... and dispatch." → declarative form
  ending in "Final prompt = shared invariants (from step 1.2.1) +
  lens body."

The exact target text per subsection (verify each against the live
file before editing — line numbers below are from the current
`parallel` branch; if the agent's `Read` shows different content,
**stop and reconcile** rather than guessing):

#### L1 (lines 316–322)

**Old:**
```
#### L1 — diff-local scan (Sonnet)

Launch one `Agent` tool-use with `model: sonnet`, `subagent_type: general-purpose`.

Prompt body: Read `fragments/lens-prompts/L1.md` — its content is the L1
prompt body verbatim. Prepend the shared invariants from step 1.2.1 and
dispatch.
```

**New:**
```
#### L1 — diff-local scan (Sonnet)

Dispatch spec: `model: sonnet`, `subagent_type: general-purpose`.

Prompt body: `fragments/lens-prompts/L1.md` (read in step 1.3's bulk
pre-read; its content is the L1 prompt body verbatim). Final prompt =
shared invariants (from step 1.2.1) + lens body.
```

#### L2 (lines 324–335)

**Old:**
```
#### L2 — structural / blast-radius (Opus; skipped if `trivial_mode`)

Launch one `Agent` tool-use with `model: opus`, `subagent_type: general-purpose`,
with `Read` and `Bash(git:*)` + `Bash(grep:*)` permissions (the sub-agent
inherits the parent command's grants — this already covers it).

L2 additionally reads surrounding files and uses `git blame` / `git log`.

Prompt body: Read `fragments/lens-prompts/L2.md` — its content is the L2
prompt body verbatim. Substitute `$prior_fix_suspects` with the JSON array
captured at step 1.2b. Prepend the shared invariants from step 1.2.1 and
dispatch.
```

**New:**
```
#### L2 — structural / blast-radius (Opus; skipped if `trivial_mode`)

Dispatch spec: `model: opus`, `subagent_type: general-purpose`. The
sub-agent inherits the parent command's `Read` + `Bash(git:*)` +
`Bash(grep:*)` grants (this already covers it).

L2 additionally reads surrounding files and uses `git blame` / `git log`.

Prompt body: `fragments/lens-prompts/L2.md` (read in step 1.3's bulk
pre-read; its content is the L2 prompt body verbatim). Per-lens
substitution: `$prior_fix_suspects` → the JSON array captured at step
1.2b. Final prompt = shared invariants (from step 1.2.1) + lens body
(with substitution applied).
```

#### L3 (lines 337–344)

**Old:**
```
#### L3 — CLAUDE.md compliance (Sonnet)

Launch one `Agent` tool-use with `model: sonnet`.

Prompt body: Read `fragments/lens-prompts/L3.md` — its content is the L3
prompt body verbatim. Substitute `$claude_md_paths` with the newline-joined
list from Phase 0 step 0.7. Prepend the shared invariants from step 1.2.1
and dispatch.
```

**New:**
```
#### L3 — CLAUDE.md compliance (Sonnet)

Dispatch spec: `model: sonnet`.

Prompt body: `fragments/lens-prompts/L3.md` (read in step 1.3's bulk
pre-read; its content is the L3 prompt body verbatim). Per-lens
substitution: `$claude_md_paths` → the newline-joined list from Phase
0 step 0.7. Final prompt = shared invariants (from step 1.2.1) + lens
body (with substitution applied).
```

#### L4 (lines 346–354)

**Old:**
```
#### L4 — comment compliance (Sonnet)

Launch one `Agent` tool-use with `model: sonnet`.

L4 additionally reads the current content of every modified file.

Prompt body: Read `fragments/lens-prompts/L4.md` — its content is the L4
prompt body verbatim. Prepend the shared invariants from step 1.2.1 and
dispatch.
```

**New:**
```
#### L4 — comment compliance (Sonnet)

Dispatch spec: `model: sonnet`.

L4 additionally reads the current content of every modified file.

Prompt body: `fragments/lens-prompts/L4.md` (read in step 1.3's bulk
pre-read; its content is the L4 prompt body verbatim). Final prompt =
shared invariants (from step 1.2.1) + lens body.
```

#### L5 (lines 356–365)

**Old:**
```
#### L5 — UX (Sonnet; skipped if `trivial_mode` or `user_facing == false`)

Launch one `Agent` tool-use with `model: sonnet`.

Prompt body: Read `fragments/lens-prompts/L5.md` — its content is the L5
prompt body verbatim (the inlined UX checklist is the canonical content;
`fragments/lens-ux-reference.md` is a redundant duplicate kept for now to
avoid scope creep). Substitute `$claude_md_paths` with the newline-joined
list from Phase 0 step 0.7. Prepend the shared invariants from step 1.2.1
and dispatch.
```

**New:**
```
#### L5 — UX (Sonnet; skipped if `trivial_mode` or `user_facing == false`)

Dispatch spec: `model: sonnet`.

Prompt body: `fragments/lens-prompts/L5.md` (read in step 1.3's bulk
pre-read; its content is the L5 prompt body verbatim — the canonical
content; `fragments/lens-ux-reference.md` is a redundant duplicate kept
for now to avoid scope creep). Per-lens substitution: `$claude_md_paths`
→ the newline-joined list from Phase 0 step 0.7. Final prompt = shared
invariants (from step 1.2.1) + lens body (with substitution applied).
```

#### L6 (lines 367–375)

**Old:**
```
#### L6 — lightweight security (Sonnet; skipped if `trivial_mode`)

Launch one `Agent` tool-use with `model: sonnet`.

Prompt body: Read `fragments/lens-prompts/L6.md` — its content is the L6
prompt body verbatim (the inlined security checklist is the canonical
content; `fragments/lens-security-reference.md` is a redundant duplicate
kept for now to avoid scope creep). Prepend the shared invariants from
step 1.2.1 and dispatch.
```

**New:**
```
#### L6 — lightweight security (Sonnet; skipped if `trivial_mode`)

Dispatch spec: `model: sonnet`.

Prompt body: `fragments/lens-prompts/L6.md` (read in step 1.3's bulk
pre-read; its content is the L6 prompt body verbatim — the canonical
content; `fragments/lens-security-reference.md` is a redundant
duplicate kept for now to avoid scope creep). Final prompt = shared
invariants (from step 1.2.1) + lens body.
```

#### L7 (lines 377–395)

**Old:**
```
#### L7 — holistic review (Opus; `ensemble_mode` only; skipped if `trivial_mode`)

Launch one `Agent` tool-use with `model: opus`, `subagent_type: general-purpose`.
Inherits the parent command's Read + Bash(git:*) + Bash(grep:*) grants — same
permissions as L2.

L7 exists as a recall-oriented safety net: focused lenses have narrower
prompts tuned to specific bug classes; L7 reads the diff like a skeptical
senior reviewer with no checklist. Ensemble-gated because it costs roughly
1.5–2x an L2 pass. Phase 2 dedup merges overlaps with focused-lens
findings (unioning `source_families`) so duplicates become a strengthening
signal via Phase 3's ≥2-families auto-graduate rule, not noise.

L7 additionally reads surrounding code and uses `git blame` / `git log`
freely.

Prompt body: Read `fragments/lens-prompts/L7.md` — its content is the L7
prompt body verbatim. Prepend the shared invariants from step 1.2.1 and
dispatch.
```

**New:**
```
#### L7 — holistic review (Opus; `ensemble_mode` only; skipped if `trivial_mode`)

Dispatch spec: `model: opus`, `subagent_type: general-purpose`.
Inherits the parent command's Read + Bash(git:*) + Bash(grep:*) grants —
same permissions as L2.

L7 exists as a recall-oriented safety net: focused lenses have narrower
prompts tuned to specific bug classes; L7 reads the diff like a skeptical
senior reviewer with no checklist. Ensemble-gated because it costs roughly
1.5–2x an L2 pass. Phase 2 dedup merges overlaps with focused-lens
findings (unioning `source_families`) so duplicates become a strengthening
signal via Phase 3's ≥2-families auto-graduate rule, not noise.

L7 additionally reads surrounding code and uses `git blame` / `git log`
freely.

Prompt body: `fragments/lens-prompts/L7.md` (read in step 1.3's bulk
pre-read; its content is the L7 prompt body verbatim). Final prompt =
shared invariants (from step 1.2.1) + lens body.
```

### Change 2: Add a closing `#### Dispatch turn` subsection

**File:** `fragments/01-detection.md`

Insert this new subsection between the end of the L7 subsection and
the start of "#### Ensemble fan-out (same turn, when
`ensemble_mode == true`)" (currently at line 397). The new subsection
becomes the unambiguous action target after all per-lens specs are
assembled.

**New text:**

```
#### Dispatch turn (one turn, all blocks)

With every applicable lens's spec assembled (L1–L7 sub-sections
above), issue every applicable lens's `Agent` tool-use in a SINGLE
orchestrator turn. The per-lens sub-sections are reference data — a
parameter sweep, not a turn sweep. Phase 1 wall-clock latency is
`max(lens_durations)`, not `sum(lens_durations)`.

Under `ensemble_mode == true`, the Ensemble fan-out's background
`Bash` calls (next sub-section) launch in this same turn — see the
"Total tool-use blocks" table below for the exact count by mode.
```

This subsection:
- Is the only action target after the per-lens specs.
- Reinforces the §1.3 top-of-section directive without restating it
  verbatim.
- Hands off cleanly to the next "#### Ensemble fan-out" subsection,
  which already sits below it and documents the additional ensemble
  blocks.

### Change 3: Fix the §1.2.1 contradiction

**File:** `fragments/01-detection.md`, lines 92–96.

**Old:**
```
The lens-body files (`fragments/lens-prompts/L<N>.md`) are read at
each lens's dispatch step (1.3). L2's body carries `$prior_fix_suspects`,
L3's and L5's bodies carry `$claude_md_paths` — substitute these the
same way before dispatch (the lens dispatch sub-sections below remind
you per-lens).
```

**New:**
```
The lens-body files (`fragments/lens-prompts/L<N>.md`) are read in
step 1.3's bulk pre-read (one parallel batch of `Read` tool-uses
before the dispatch turn). L2's body carries `$prior_fix_suspects`,
L3's and L5's bodies carry `$claude_md_paths` — substitute these the
same way before the dispatch turn (the lens dispatch sub-sections
below specify the per-lens substitutions).
```

Two changes:
- "are read at each lens's dispatch step (1.3)" → "are read in
  step 1.3's bulk pre-read (one parallel batch of `Read` tool-uses
  before the dispatch turn)".
- "the lens dispatch sub-sections below remind you per-lens" → "the
  lens dispatch sub-sections below specify the per-lens substitutions"
  (drops the "remind" framing that implied per-lens-at-dispatch reads).

### Change 4: Strengthen smoke `CR-12`

**File:** `test/smoke.sh`, lines 5610–5637.

Split into two sub-checks:
- `CR-12a` (existing): the §1.3 top-of-section directive is present.
- `CR-12b` (new): the §1.3 per-lens subsections (L1 through L7
  inclusive) contain ZERO imperative dispatch phrases.

**Old (lines 5610–5637):**
```bash
# CR-12: fragments/01-detection.md §1.3 carries an emphatic top-of-section
# parallel-dispatch directive between the section header and the first L1
# sub-section. The lens-prompt extraction (L1–L7 moved to
# fragments/lens-prompts/) replaced inline blockquoted prompts in §1.3
# with per-lens "Prompt body: Read fragments/lens-prompts/L<N>.md … and
# dispatch" recipes. Each per-lens sub-section then reads as a self-
# contained "Read X then dispatch Agent" pair, which an orchestrator
# processing the fragment top-to-bottom can interpret as a serial
# action — defeating the parallel dispatch this phase depends on
# (Phase 1 wall-clock goes from max → sum). Mirrors the emphatic
# "SINGLE orchestrator turn" directive in fragments/01-codex-detection.md
# §1.3 (line ~188).
#
# Guard: the substring "SINGLE orchestrator turn" must appear inside §1.3
# *between* the §1.3 header and the §1.3 first L1 sub-section ("#### L1").
# An awk window keeps the assertion targeted: a SINGLE-turn mention
# elsewhere in the fragment (e.g. a hypothetical §1.4) would not satisfy
# the §1.3 placement contract.
cr12_window=$(awk '
    /^### 1\.3\./        {in_window=1; next}
    /^#### L1 /          {if (in_window) in_window=0}
    in_window            {print}
' "$REPO/fragments/01-detection.md" | tr '\n' ' ')
if printf '%s' "$cr12_window" | grep -qE 'SINGLE[[:space:]]+orchestrator[[:space:]]+turn'; then
    pass "CR-12: fragments/01-detection.md §1.3 carries top-of-section SINGLE-turn parallel-dispatch directive (regression guard for lens-prompt extraction serializing dispatch)"
else
    fail "CR-12: fragments/01-detection.md §1.3 missing top-of-section 'SINGLE orchestrator turn' directive between §1.3 header and the first L1 sub-section"
fi
```

**New:**
```bash
# CR-12: fragments/01-detection.md §1.3 parallel-dispatch contract.
# Two-part guard against the lens-prompt-extraction regression class
# (PR #23 + the partial fix in 0466d04, then re-reproduced 2026-05-03
# on beta-briefing/onboard-page despite the directive being live).
#
# CR-12a: top-of-section "SINGLE orchestrator turn" directive present
# between the §1.3 header and the first L1 sub-section.
#
# CR-12b: per-lens sub-sections (#### L1 through end of §1.3) contain
# ZERO imperative dispatch phrases ("Launch one `Agent` tool-use" /
# "and dispatch."). The directive's prose alone is not load-bearing
# — local imperatives in the per-lens sub-sections override it
# structurally. This guard fails if a future fragment edit
# reintroduces imperative-shaped per-lens recipes.
#
# CR-12a window: between "### 1.3." and "#### L1 ".
# CR-12b window: between "#### L1 " and "### 1.4." (catches all per-lens
# sub-sections L1–L7 plus any closing dispatch sub-section before §1.4).

cr12a_window=$(awk '
    /^### 1\.3\./        {in_window=1; next}
    /^#### L1 /          {if (in_window) in_window=0}
    in_window            {print}
' "$REPO/fragments/01-detection.md" | tr '\n' ' ')
if printf '%s' "$cr12a_window" | grep -qE 'SINGLE[[:space:]]+orchestrator[[:space:]]+turn'; then
    pass "CR-12a: fragments/01-detection.md §1.3 carries top-of-section SINGLE-turn parallel-dispatch directive (regression guard for lens-prompt extraction serializing dispatch)"
else
    fail "CR-12a: fragments/01-detection.md §1.3 missing top-of-section 'SINGLE orchestrator turn' directive between §1.3 header and the first L1 sub-section"
fi

# Flatten newlines before the imperative grep — the per-lens prose
# wraps at ~70 chars, so "and\ndispatch." (two-line wrap) is exactly
# the failure mode this guard targets. Mirrors PFD-9's tr-flatten
# pattern; without it a wrapped "Launch one ... and\ndispatch." would
# slip past line-anchored grep -c.
cr12b_window_flat=$(awk '
    /^#### L1 /     {in_window=1}
    /^### 1\.4\./   {in_window=0}
    in_window       {print}
' "$REPO/fragments/01-detection.md" | tr '\n' ' ')
cr12b_imperatives=$(printf '%s\n' "$cr12b_window_flat" \
    | grep -oE '(Launch one `Agent` tool-use|and[[:space:]]+dispatch\.)' \
    | wc -l \
    | tr -d '[:space:]')
if [[ "$cr12b_imperatives" == "0" ]]; then
    pass "CR-12b: per-lens sub-sections in fragments/01-detection.md §1.3 contain no imperative dispatch phrases (regression guard for serial-dispatch reintroduction via per-lens recipes)"
else
    fail "CR-12b: $cr12b_imperatives imperative dispatch phrase(s) ('Launch one \`Agent\` tool-use' / 'and dispatch.') found in fragments/01-detection.md §1.3 per-lens sub-sections — these reintroduce serial dispatch despite the §1.3 top-of-section directive"
fi
```

Note: smoke runs under `set -u` only (test/smoke.sh:17 explicitly
opts out of `-e` with the comment "intentionally no -e: we manage
failures per-assertion"), so `grep -oE | wc -l` returns a clean `0`
when the regex doesn't match — no `|| true` needed. The earlier
draft of this plan called for `grep -cE | … || true` with a `set -e`
rationale; both pieces were wrong (smoke isn't `-e`, and `grep -c`
is line-anchored, which would miss wrapped imperatives — see PFD-9
in the same diff for the same wrap problem and its `tr '\n' ' '`
fix). The shipped form mirrors PFD-9: flatten then count matches.

The `cr12b_window_flat` awk windows from `#### L1 ` through
`### 1.4.` — that captures L1, L2, L3, L4, L5, L6, L7, AND the new
"#### Dispatch turn" + "#### Ensemble fan-out" subsections. The new
"#### Dispatch turn" subsection's text uses "issue every applicable
lens's `Agent` tool-use" (NOT "Launch one") and contains no "and
dispatch." phrase, so it does not trip CR-12b. Verify this when
adding the closing subsection.

### Change 5: Plugin version bump

**File:** `.claude-plugin/plugin.json`

Bump `version` from `0.3.1` to `0.3.2` (plan was drafted when 0.3.0
was current; the codex-review feature ship at PR #23 took live to
0.3.1 before this fix landed). Patch bump per CLAUDE.md release
discipline — this is a behavior correction (Phase 1 actually
parallelizes now), not a docs-only change.

---

## Test plan

1. **Smoke runs clean before edits.** `test/smoke.sh` should pass
   312/312. (Already verified during plan drafting.)

2. **Each per-lens edit applied in isolation should still leave smoke
   at 312.** The CR-12a check is unaffected by edits below the L1
   header; CR-12b doesn't exist yet. So after Changes 1–3 (fragment
   edits) but before Change 4 (smoke edit), smoke should still pass
   312/312. If it fails, the edits introduced a different regression
   — stop and reconcile.

3. **After Change 4 (smoke edit), smoke should pass 313/313.** One new
   assertion (CR-12b) added. CR-12a still passes (the top directive is
   untouched). CR-12b passes because all per-lens imperatives have
   been removed by Changes 1–2.

4. **Negative-test the CR-12b guard.** Before committing, temporarily
   reintroduce one "and dispatch." in the L1 subsection (e.g. by
   reverting the L1 edit), run smoke, and confirm CR-12b fails with
   "1 imperative dispatch phrase(s) found." Restore the edit. This
   confirms the guard would catch a future regression.

5. **No live `/adamsreview:review` test required for this fix.** The
   fix is fragment-prose-only; behavior verification would require a
   real PR review and is out of scope for a same-day patch. The user
   can re-test on their `onboard-page` worktree post-merge.

---

## Risk / blast radius

- **No code path runs differently as a direct result of this change.**
  Helper scripts, schema, validators are all untouched. The fragment
  prose change shifts how the orchestrator interprets §1.3, which is
  the intended fix.
- **`/adamsreview:codex-review` is not affected.** Different fragment.
  Verified `01-codex-detection.md` is structurally clean.
- **`/adamsreview:add` is not affected.** Doesn't run Phase 1 lens
  detection; uses a separate paste-normalizer flow.
- **`/adamsreview:fix` and `/adamsreview:walkthrough` are not
  affected.** No lens dispatch in those flows.
- **The fix is reversible.** Single-PR revert restores the previous
  fragment text and smoke. If the fix turns out to confuse the
  orchestrator in a different way, revert is clean.

The only thing the fresh agent should be careful about: the per-lens
text replacements involve multi-line `old_string` matches. If any
subsection has been edited since this plan was drafted (verify via
the live `Read` of the file), reconcile before applying — don't
guess.

---

## Commit message draft

```
Phase 1 parallel dispatch: strip per-lens imperatives (v0.3.2)

The 0466d04 fix added an emphatic "Parallel dispatch — load-bearing"
directive at the top of fragments/01-detection.md §1.3, but left 7
per-lens subsections each carrying "Launch one `Agent` tool-use" +
"Read X and dispatch" imperatives. Local imperatives override the
distant directive — the orchestrator follows each per-lens recipe as
its own turn, defeating the parallelism the section depends on.

User reproduced this on beta-briefing/onboard-page running
/adamsreview:review --ensemble: all 7 lenses ran serially despite the
directive being present.

Convert per-lens subsections to declarative spec form:
- "Launch one `Agent` tool-use with `model: X`..." → "Dispatch spec:
  `model: X`..."
- "Read `fragments/lens-prompts/L<N>.md` ... and dispatch." → "Prompt
  body: `fragments/lens-prompts/L<N>.md` (read in step 1.3's bulk
  pre-read). Final prompt = shared invariants + lens body."

Add a single closing "#### Dispatch turn" subsection between L7 and
"Ensemble fan-out" — unambiguous action target.

Fix the contradicting line in §1.2.1 ("are read at each lens's
dispatch step") to describe the bulk pre-read.

Smoke CR-12 split into CR-12a (existing presence guard) + CR-12b (new:
forbids imperative dispatch phrases inside per-lens subsections).
Smoke 312 → 313.

Plugin version bumped 0.3.1 → 0.3.2.

/adamsreview:codex-review is structurally robust against this bug
class (single recipe with L${N} substitution, no per-lens
subsections); no changes there.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Out of scope but worth noting (for backlog)

- **Long-term thought:** the per-lens subsections' "reading scope"
  notes (L2 reads surrounding files, L7 reads diff broadly, L4 reads
  every modified file) might be better moved INTO the lens-prompt
  files themselves so the orchestrator-side fragment becomes a pure
  dispatch spec table. Defer — that's a larger refactor and not
  required to fix the current regression.
- **CR-12 windowing fragility:** both CR-12a and CR-12b depend on the
  awk header-match regex (`^### 1\.3\.`, `^#### L1 `, `^### 1\.4\.`).
  If those headers ever get reordered or renamed, both checks
  silently no-op (empty window grep matches nothing). Consider adding
  an "expected non-empty window" sanity assertion. Not done here to
  keep the diff focused; file as a follow-up if it bites.
