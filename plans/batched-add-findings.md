# Plan: batched `--add-findings` mode for `artifact-patch.py`

**Status:** draft, not yet approved. Updated 2026-04-26 to fold in
plan-review feedback (schema-derived whitelist; in-jq family
canonicalization promoted from "out of scope" to a first-class change;
risk-section reframing; assorted editorial fixes). Updated 2026-04-26
(second pass) to address validator-rebuild-per-finding (B1: hoist
finding-validator construction out of the per-finding loop), in-jq
whitespace/empty handling (B2: match `map_family()` normalization
semantics), distinct exit code for the all-rejected case (R1: new
`EXIT_ALL_REJECTED=7`), louder failure surface for the total-failure
case (R2: new `phase_1_add_findings_total_failure:` audit tag),
per-rejection stderr trimming (R3: single machine-greppable line
per rejection, no err_prompt block), schema-errors overflow convention
matching `_write_and_emit` (R4), test coverage for nested
additionalProperties (R5), and a fragment-side count-mismatch check
that subsumes the deferred `--expected` guard for Phase 1. Updated
2026-04-26 (third pass) after independent reviews from Claude (in-
session) and Codex (gpt-5.5 high effort) to address: stderr-tee race
in the new total-failure block (T1: synchronous tempfile capture),
dead-code finding_property_keys/ALLOWED_ADD_FINDING_KEYS (T2: drop
both — schema validator catches `additionalProperties` at every
depth), drift-table maintenance via smoke-driven agreement check
(T3), CLI docstring update spots beyond `build_parser()` (T4),
AF-* coverage gap for usage errors (T5), CLAUDE-rule-4 error-as-prompt
contract on the all-rejected exit (T6: add batch-level err_prompt),
exit-code policy docstring contradicting the actual code (T7: 64 =
malformed input / wrong type / CLI misuse, 1 = post-write full-
artifact validation failure), non-string `source_family` jq fragility
(T8: type-guard fam_canonical), single-Bash-invocation execution
discipline (T9: explicit fragment note + scratch-file fallback), top-
of-fragment prose drift (T10: update §1 overview), and the existing
PF-INT-4 smoke guard going stale (T11: replace its grep markers).
AF-5 (defense-in-depth post-write) is reframed contingent on
identifying a real fixture — see Section 5. Updated 2026-04-26
(fourth pass) with empirical data on Wave 2 deferral: 44 reviews on
file, Wave 2 fired in 3 (~7%), peak count 3 — strengthens the
"Out of scope" reasoning from "defer until measurable cost" to
"defer indefinitely; see triggers."
**Branch:** `writing-issues`
**Scope:** Phase 1 join step (`fragments/01-detection.md` §1.5 step 4)
only. Two parallel `--add-finding` sites (`fragments/05-validation.md`
Wave 2; `commands/add.md` step 6) are explicitly deferred — see
"Out of scope" below.

## Motivation

Phase 1's join step today commits each candidate finding via its own
`artifact-patch.py --add-finding` call. The fragment text *looks* like
one shell `while` loop, but the surrounding prose ("On non-zero exit
for any single `--add-finding`, read the error-as-prompt, adjust your
jq build, retry once") is orchestrator-level instruction — only Claude
can interpret an error-as-prompt block and re-emit a corrected build.
So in practice the orchestrator runs each iteration as its own Bash
tool-use, which means N candidates produce N transcript request/response
pairs, each carrying a full schema-shaped finding object inline.

Two costs follow from that. The visible one is **orchestrator-context
bloat**: with 50 candidates, ~100 transcript entries are dedicated to
"save these to disk." The less visible one is **wall-clock**: each
Bash dispatch is dominated by model-API round-trip latency (a few
hundred milliseconds), so 50 round-trips add 10–25 s on top of the
actual work. The most recent in-progress review on `beta-briefing`
made both surfaces obvious enough that the user flagged them.

Phase 4, 8, and 9 already collapse equivalent per-finding loops via
batched helper modes (`--apply-decisions`, `--apply-fix-start`,
`--apply-fix-outcomes`). CLAUDE.md's "Batched-helper pattern" section
explicitly invites new batched modes to reuse that scaffolding. Phase
1 is the largest remaining per-finding-loop site in the canonical
pipeline; this plan closes it.

## Approach in one paragraph

Add a new mutually-exclusive `--add-findings` (plural) mode to
`artifact-patch.py` that takes a JSON array of findings and commits
them in a single atomic write, with continue-on-error semantics for
malformed individual findings. Replace the Phase 1 fragment's per-
candidate loop with two pieces: (a) one `jq` invocation that
canonicalizes the source-family inline, builds the full schema-shaped
finding objects, and emits a JSON array; and (b) one batched helper
call that streams that array via stdin. The result is one orchestrator
Bash request and one response, regardless of N.

## What the new mode does and where it differs from existing batched modes

The existing `--apply-decisions` / `--apply-fix-*` modes mutate
*existing* findings, one per tuple, with per-tuple atomic writes and
first-failure halt. That recovery shape is right for mutations: when
tuple #N is invalid, tuples 0..N-1 still represent meaningful state
changes, and the caller re-invokes with the remainder.

`--add-findings` *creates* findings, which calls for two deliberate
divergences:

- **Continue-on-error, not first-failure-halt.** A malformed input is
  a candidate-level problem, not a batch-level one. The helper logs a
  structured rejection block on stderr and skips the bad finding;
  the rest of the batch proceeds. This preserves the today's
  drop-and-continue behavior of the per-call `--add-finding` loop the
  caller is replacing, and avoids forcing the orchestrator into a
  multi-round-trip recovery for a batch with multiple bad shapes.
- **One atomic write at the end, not per-tuple.** Adds don't have the
  same "every accepted item is independently meaningful" property that
  mutations do — for creates, all-or-nothing across the *accepted*
  set is cleaner. (Rejections are filtered before the write; the
  on-disk artifact transitions in one step.)

The mode accepts input via stdin (`-`), `@file`, or inline JSON, same
as every other mode. Phase 1's caller will use stdin to keep the
findings-array out of the shell command body and out of any argv
limits.

## Concrete changes

### 1. `bin/_common.py` — per-finding validator factory, validator-taking validate, new exit code

Two additions plus one constant, all reusing the existing
`_load_validator()` plumbing that powers `validation_result_validator()`:

- A new `EXIT_ALL_REJECTED = 7` constant — `--add-findings`'s exit code
  for the case where every input was rejected (distinct from
  `EXIT_VALIDATION` so a downstream caller can branch on "your input
  shape was wrong" vs. "every individual finding was bad").
- `finding_validator()` — factory that builds the per-finding
  Draft202012Validator once. Mirrors `validation_result_validator()`.
  Hoisted out of the per-finding loop because `_load_validator()`
  re-reads `schema-v1.json` from disk + runs `check_schema()` on every
  call, and `Registry().with_resource(...)` isn't free either; doing
  these N times in a 50-candidate batch erases most of the helper-side
  wall-clock win the batched mode is designed to deliver.
- `validate_finding(finding, validator)` — takes the pre-built
  validator. Caller is responsible for calling `finding_validator()`
  once and reusing across the batch.

**T2 — no `finding_property_keys()`.** An earlier draft of this plan
proposed a `finding_property_keys()` helper that exposed the schema's
finding property names, on the theory that `--add-findings` would
maintain a separate "unknown keys" check derived from the schema. Both
review passes (Claude in-session + Codex high-effort) flagged this as
dead code: `validate_finding(finding, validator)` already catches
`additionalProperties: false` violations at every depth the schema
declares them — top-level finding plus nested
`validation_result.blast_radius`, `human_confirmation`,
`human_confirmation.promoted_from`, `score_history` items, and the
`validation_result` / `verification_context` sub-objects. A separate
key-list check would be a redundant fast path with its own
maintenance burden (drift between the helper's whitelist and the
schema). Drop it. If a future caller ever wants a more legible
"unknown_keys: ['foo']" rejection reason than the raw schema-error
text, add the check at that call site.

```python
EXIT_ALL_REJECTED = 7  # --add-findings: every input was rejected (no findings landed)


def finding_validator():
    """Return a Draft202012Validator bound to `#/$defs/finding`.

    Mirrors validation_result_validator() — registers the full schema
    with a referencing.Registry and validates against a $ref so
    internal $refs (impact_type_enum, line_range, fix_attempt, etc.)
    resolve correctly. Catches additionalProperties violations
    everywhere the schema declares them — top-level finding object AND
    nested objects (validation_result.blast_radius, human_confirmation,
    score_history items, etc.) — in one validator pass.

    Build ONCE per batch and pass the result into validate_finding();
    don't call this per-finding. _load_validator() reads schema-v1.json
    from disk and runs Draft202012Validator.check_schema(schema) every
    call, and Registry construction has its own non-trivial cost. For a
    50-candidate batch the rebuild work is a measurable share of the
    wall-clock win the batched mode is designed to deliver.
    """
    schema, Validator = _load_validator()
    try:
        from referencing import Registry, Resource
        from referencing.jsonschema import DRAFT202012
    except ImportError:
        err_prompt(
            "missing Python dependency 'referencing' (ships transitively with jsonschema>=4.18)",
            action="verify the calling script's inline `# /// script` dep list includes 'jsonschema'."
        )
        sys.exit(EXIT_MISSING_DEP)
    resource = Resource(contents=schema, specification=DRAFT202012)
    registry = Registry().with_resource(uri=schema.get("$id", ""), resource=resource)
    ref_schema = {"$ref": f"{schema.get('$id', '')}#/$defs/finding"}
    return Validator(ref_schema, registry=registry)


def validate_finding(finding, validator):
    """Validate a single finding against #/$defs/finding using a pre-built validator.

    Returns a list of human-readable error strings (empty list on valid).
    Caller is responsible for building `validator` once via
    finding_validator() and reusing across the batch.

    Errors include additionalProperties violations at every level the
    schema declares them — caller doesn't need a separate unknown-keys
    check at the call site.
    """
    errors = []
    for e in sorted(validator.iter_errors(finding), key=lambda x: list(x.absolute_path)):
        path = _pretty_path(e.absolute_path) or "(root)"
        errors.append(f"${path}: {e.message}")
    return errors
```

### 2. `bin/artifact-patch.py` — new `--add-findings` mode

The mode follows the existing scaffolding pattern (`read_json_arg` →
preflight → write → summary line on stdout). The differences from
`--apply-decisions` et al. are local to the per-tuple loop and the
write step.

```python
def cmd_add_findings(args):
    """Append a batch of new findings to findings[] in one atomic write.

    Diverges from --apply-decisions / --apply-fix-* in two ways:

    1. Continue-on-error: malformed findings are logged on stderr and
       skipped; the rest of the batch still commits. This preserves
       the drop-and-continue behavior of the per-call --add-finding
       loop the caller is replacing — a malformed shape is a
       candidate-level problem, not a batch-level one.

    2. Single atomic write: all accepted findings append in one
       tmp+rename, not per-finding. Crash semantics are all-or-nothing
       across the accepted set.

    Exit-code policy (pinned here so future callers can rely on it).
    T7 — earlier draft contradicted the actual code; this is the
    code-aligned spec:
      - 0       : at least one finding accepted (rejections allowed; the
                  summary line names the skipped ids).
      - 1       : EXIT_VALIDATION — the post-write full-artifact schema
                  validation failed (defense-in-depth: per-finding
                  preflight passed but the artifact-level check
                  rejected). Should be rare given the per-finding
                  validator and the artifact-level validator share
                  schema-v1.json; if it fires, that's a preflight bug
                  to investigate.
      - 7       : EXIT_ALL_REJECTED — input was a JSON array, but every
                  element was rejected at the per-finding preflight.
                  Distinct from 64 so a downstream caller can branch on
                  "every finding was bad" vs. "your input shape was
                  wrong." Phase 1's fragment handler treats both the
                  same; /adamsreview:add migration may want to branch.
      - 64      : EXIT_USAGE — malformed input up front. Two pathways
                  share this: (a) `read_json_arg()` already exits 64
                  when stdin / @file / inline isn't parseable JSON;
                  (b) this mode emits 64 when the parsed value isn't a
                  JSON array. Plus mode-conflict (--add-findings
                  combined with --set / --finding-id / etc.).

    Stderr per-rejection format (machine-greppable; ONE line per
    rejected finding — no err_prompt block, to keep trace.md compact
    on a 30-rejection batch):
      add-findings-rejected: idx=<n> id=<F or "(missing)"> reason=<short> detail=<short>

    Stdout summary (one line, always emitted):
      added <N> findings (skipped <M>: [F012, F037, ...])
    """
    findings = read_json_arg(args.add_findings, "--add-findings")

    if not isinstance(findings, list):
        c.err_prompt(
            f"--add-findings expects a JSON array, got {type(findings).__name__}",
            action="pass an array of finding objects (inline JSON, @file, or - for stdin)."
        )
        return c.EXIT_USAGE

    artifact = _load_or_fail(args.path)
    existing_ids = {f.get("id") for f in artifact.get("findings", [])}

    # Build the per-finding validator ONCE (B1). _load_validator()
    # opens schema-v1.json + runs check_schema(); Registry construction
    # isn't free either. Hoisting both out of the per-finding loop is
    # a measurable share of the wall-clock win this mode is designed
    # to deliver — at 50 candidates the rebuild cost dominates the
    # actual validation work otherwise.
    finding_v = c.finding_validator()

    accepted = []
    rejected = []
    seen_in_batch = set()

    for idx, finding in enumerate(findings):
        rejection = _check_add_finding_shape(
            finding, idx, existing_ids, seen_in_batch, finding_v
        )
        if rejection is not None:
            rejected.append(rejection)
            _emit_rejection(rejection)
            continue
        accepted.append(finding)
        seen_in_batch.add(finding["id"])

    if not accepted and rejected:
        # Every input was bad. Don't bother writing. Distinct exit
        # code (EXIT_ALL_REJECTED, 7) so a downstream caller can
        # distinguish "every individual finding was rejected" from
        # "your input shape was wrong" (EXIT_USAGE, 64) or "post-write
        # validation failed" (EXIT_VALIDATION, 1).
        #
        # T6 — operational rule 4 says non-zero helper exits emit
        # ERROR / Action error-as-prompt blocks. The per-rejection
        # stderr lines (one per dropped finding) are intentionally
        # compact — but the BATCH outcome still needs the standard
        # recovery surface. Emit a batch-level err_prompt before the
        # summary line so the orchestrator sees a familiar shape.
        c.err_prompt(
            f"--add-findings: every input was rejected ({len(rejected)} of {len(rejected)})",
            context=[
                "no findings landed; on-disk artifact unchanged.",
                "per-rejection detail above (one `add-findings-rejected:` line per drop).",
            ],
            action=(
                "investigate the rejection reasons (schema_invalid / duplicate_id / "
                "missing_id / not_object). If the rejections are upstream lens drift, "
                "fix the lens prompt or the jq builder; if they're a single bad "
                "finding, drop it from the input and re-invoke."
            ),
        )
        print(f"added 0 findings (skipped {len(rejected)}: {[r['id'] for r in rejected]})")
        return c.EXIT_ALL_REJECTED

    # Empty input: succeed silently with a 0-count summary so callers
    # can pipe a possibly-empty array without special-casing.
    if not accepted:
        print("added 0 findings")
        return c.EXIT_OK

    # In-memory mutation note (N6): extend() mutates `artifact` in
    # place. If the post-write validation below fails, the on-disk
    # file stays at its prior state (correct), but this in-process
    # `artifact` dict carries the bad findings until the process
    # exits. Fine in the current one-mode-per-process model; flag if
    # that ever changes (e.g. an embedded use of artifact-patch).
    artifact.setdefault("findings", []).extend(accepted)

    # _write_and_emit re-runs full-artifact schema validation. If
    # preflight let something through (e.g., an artifact-level
    # invariant the per-finding sub-schema can't see), this fires
    # rather than silently corrupting the on-disk artifact. The
    # accepted batch is one transaction: every accepted finding lands
    # or none do.
    rc = _write_and_emit(args.path, artifact, silent=True)
    if rc != c.EXIT_OK:
        # _write_and_emit already emitted an error-as-prompt to stderr
        # naming the failed schema rule. No need to re-report (R3).
        return rc

    rejected_ids = [r["id"] for r in rejected]
    print(
        f"added {len(accepted)} findings"
        + (f" (skipped {len(rejected)}: {rejected_ids})" if rejected else "")
    )
    return c.EXIT_OK


def _check_add_finding_shape(finding, idx, existing_ids, seen_in_batch, validator):
    """Run preflight checks on one candidate finding.

    Rejection reasons:
      - "not_object"     : non-dict input
      - "missing_id"     : no id field (fast-path before schema check)
      - "duplicate_id"   : id already in artifact OR earlier in batch
      - "schema_invalid" : validate_finding() returned errors. Covers
                           top-level AND nested additionalProperties
                           violations (e.g. validation_result.blast_radius
                           extra keys, score_history item extras), bad
                           enum values, missing required fields, and
                           shape mismatches in one pass — no separate
                           "unknown_keys" check.
    """
    fid = (finding.get("id") if isinstance(finding, dict) else None) or "(missing)"

    if not isinstance(finding, dict):
        return {"idx": idx, "id": fid, "reason": "not_object",
                "detail": f"got {type(finding).__name__}"}

    if not finding.get("id"):
        return {"idx": idx, "id": fid, "reason": "missing_id",
                "detail": "every finding needs an id (FXXX); run assign-finding-ids.sh upstream"}

    if finding["id"] in existing_ids:
        return {"idx": idx, "id": fid, "reason": "duplicate_id",
                "detail": "id already exists in artifact"}
    if finding["id"] in seen_in_batch:
        return {"idx": idx, "id": fid, "reason": "duplicate_id",
                "detail": "id appears twice in this batch"}

    schema_errors = c.validate_finding(finding, validator)
    if schema_errors:
        # Match _write_and_emit's existing 10-with-overflow convention
        # (R4) so the rejection block doesn't silently drop the long
        # tail of a deeply-broken finding.
        shown = schema_errors[:10]
        if len(schema_errors) > 10:
            shown.append(f"(+{len(schema_errors) - 10} more)")
        return {"idx": idx, "id": fid, "reason": "schema_invalid",
                "detail": shown}

    return None


def _emit_rejection(rejection):
    """Write one machine-greppable rejection line to stderr.

    Single line per rejection — NO err_prompt block per rejection.
    Earlier draft emitted ERROR/context/action triplet per drop, which
    on a 30-rejection batch produced ~180 lines of trace.md noise; the
    single-line shape keeps per-rejection cost flat with what the
    pre-batch loop logged (one line per drop in trace.md). The full
    err_prompt format is reserved for batch-level failures (bad input
    shape, all-rejected summary) where the extra context helps the
    orchestrator diagnose.
    """
    detail = rejection["detail"]
    detail_str = "; ".join(detail) if isinstance(detail, list) else str(detail)
    # Cap the on-line representation so trace.md stays scannable. The
    # full schema-error list lives in `detail` above — render in full
    # only on demand (e.g., if an operator wants to dump the rejected
    # batch via a future debug helper).
    if len(detail_str) > 200:
        detail_str = detail_str[:197] + "..."
    print(
        f"add-findings-rejected: idx={rejection['idx']} "
        f"id={rejection['id']} reason={rejection['reason']} "
        f"detail={detail_str}",
        file=sys.stderr,
    )
```

**T4 — three CLI-text spots to update, not one.** Earlier draft only
mentioned `build_parser()`. The full set:

1. **Top-of-file module docstring (lines 8–56 of `artifact-patch.py`).**
   Lists every mode with a short description; add a `--add-findings
   <array>` entry describing the continue-on-error + single-atomic-
   write divergence.
2. **`build_parser()` mode-group entry** (below).
3. **`main()`'s "no mode selected" error string** (currently:
   `parser.error("no mode selected (use --init, --add-finding,
   --delete-finding, ...)")`) — append `--add-findings` to the list so
   the help text stays accurate.

CLI plumbing in `build_parser()`:

```python
mode.add_argument(
    "--add-findings",
    dest="add_findings",
    metavar="FINDINGS_JSON",
    help="batched: append a JSON array of findings in one atomic write "
         "(inline JSON, @file, or - for stdin). Continues on per-finding "
         "validation failures; emits structured stderr per rejection."
)
```

`main()` dispatch (slot in immediately AFTER the existing
`--add-finding` (singular) block, BEFORE `--delete-finding`, so the
related-modes ordering stays grouped):

```python
if args.add_findings is not None:
    if args.set or args.set_json or args.append_fix_attempt or args.finding_id:
        parser.error("--add-findings cannot combine with --set / --set-json / --append-fix-attempt / --finding-id (each finding carries its own id)")
    if args.dry_run:
        # Note: unlike --apply-decisions/--apply-fix-*, --add-findings
        # does a single atomic write, so --dry-run could be made
        # meaningful here (rehearse preflight + post-write validation
        # without committing). Leaving it rejected for the minimum
        # version to keep parity; promote to supported when the first
        # caller asks for it.
        parser.error("--add-findings does not currently support --dry-run (use a throwaway --path to preflight)")
    return cmd_add_findings(args)
```

### 3. `fragments/01-detection.md` — collapse the loop, with in-jq family canonicalization

This is where the orchestrator-context win actually lands. The
existing code (lines 967-1007) loops in shell and forks four
subprocesses per candidate (one `source-family-map.py`, three `jq`).
The new code does the whole pool in one `jq` invocation, then makes
one batched helper call.

**T10 — top-of-fragment prose drift.** Beyond §1.5 step 4, the §1
overview at line ~8 currently says: *"The orchestrator merges all
lens outputs into `artifact.findings[]` as one call per candidate to
`artifact-patch.py --add-finding`."* That sentence becomes false after
this change. Update it to: *"The orchestrator merges all lens outputs
into `artifact.findings[]` via a single batched `artifact-patch.py
--add-findings` call (see §1.5 step 4)."* Same paragraph, one-line
edit. Identified by Codex; the plan's earlier scope only covered the
§1.5 step body and missed this overview line.

**T9 — single-Bash-invocation execution discipline.** The
orchestrator-context savings claim depends on `$ided`, `$build_result`,
and `$findings_array` being built and consumed within ONE Bash
tool-use. Bash variables don't enter the orchestrator transcript
unless explicitly printed — so as long as assign-IDs / build / add
all run inside one `Bash(...)` call, the per-finding JSON never
crosses the orchestrator-helper boundary as text.

If the orchestrator splits assign-IDs (step 3) and build+add (step 4)
into SEPARATE Bash calls, `$ided` has to be re-injected into the
second call's command body — putting the JSON pool back into the
transcript and undoing most of the win. The fragment's prose at §1.5
already groups steps 3 and 4 in one bash block, but make this
explicit:

> **Execution note (T9).** Steps 3 and 4 in this section MUST run
> inside a single `Bash(...)` invocation. The shell variables
> (`$ided`, `$build_result`, `$findings_array`) are large and pulling
> them through the orchestrator transcript between two Bash calls
> negates the batched-helper context win. If the orchestrator finds
> itself needing to split (e.g., to insert a tool-use between the two
> steps), use a scratch file: write `$ided` to
> `$scratch_dir/phase1_pool.json` at the end of step 3 and read it
> back via `--add-findings @$scratch_dir/phase1_pool.json` at step 4.
> Scratch files don't enter the transcript; ad-hoc command-line
> arguments do.

The two motivations stack. Collapsing the orchestrator dispatch from N
to 1 saves transcript and round-trip latency — that's the unambiguous
win and is what the recent beta-briefing review made visible. Inlining
the source-family canonicalization in `jq` removes per-candidate
Python forks; the wall-clock win there is approximately
uv-startup-cost × N, but uv caches well so the actual per-call cost
is in the tens-of-ms to ~150 ms range and needs measurement on a
real review to size honestly (N5). After both changes, Phase 1 join
becomes one orchestrator Bash call wrapping one `jq` and one helper
subprocess, regardless of N — and the helper-side per-finding cost
drops to one preflight against a hoisted, pre-built validator (B1)
rather than one process+schema-load per finding.

The drift table (`stale-line-ref → policy-family`,
`prompt-injection → security-family`, etc.) currently lives in
`bin/source-family-map.py`. It's small (six entries with underscore
aliases) and historically stable (last extension was 2026-04-22).
The tradeoff for the in-jq inlining is that this table now lives in
two places — when a new drift pattern is observed in trace.md, both
files need updating. The two ARE separate implementations (jq
if/elif chain vs. Python dict lookup), not two readers of one table.
Mitigations (in order of strength): (1) the **AF-DRIFT smoke
assertion** (T3, Section 5) iterates every key in the helper's
`CANONICAL` set + `DRIFT_MAP` and asserts both implementations agree
— a new key added to one but not the other fails this assertion
immediately; (2) the in-helper docstring cross-reference (below)
points the next extender at the second site; (3) the soft runtime
fallback to `source_family: "unknown"` + `lens_source_family_unknown:`
audit logging surfaces drift in trace.md if it ever does land in
production. Acceptable given (a) the infrequency of drift extensions,
(b) the scope-locality (only Phase 1 join needs the in-jq form;
`/adamsreview:add` and Wave 2 don't canonicalize), and (c) the
multi-layer mitigation above.

`source-family-map.py` becomes near-dead-code post-this-change: the
schema doesn't constrain `source_families` via enum (it's just
`array of string with minLength 1`), so the helper isn't structurally
required by validation. Neither remaining call site canonicalizes —
`/adamsreview:add` builds `source_families: [.source_family]` directly,
and Wave 2 hardcodes `["structural-family"]`. The helper stays in the
repo because (a) it's small and well-tested (smoke MP-* assertions
still cover it), and (b) it remains the documented single-shot form
for ad-hoc debugging / future callers. **Add a one-line cross-
reference to `bin/source-family-map.py`'s module docstring** pointing
readers at `fragments/01-detection.md` §1.5 step 4, so a future
drift-table extender sees the second site. (Discussion item 1
resolution: a future cleanup PR could either retire the helper or
invert the dependency by generating the jq snippet from Python at
build time — both are out of scope here; the plugin currently has no
build step and adding one for this single piece of logic is
over-engineering.)

The replacement looks like this:

```bash
# Single jq pass: canonicalize source_family, build full schema-shaped
# findings, and identify any unknown-family rows in one walk over the
# pooled candidates. The function definitions live inside the jq
# program so they're co-located with their callers.
build_result=$(printf '%s' "$ided" | jq -c --argjson trivial "$trivial_mode" '
  # Canonicalize a raw source_family string to one of the eight known
  # families, or null for unknown. Match map_family() normalization
  # semantics (the Python function inside bin/source-family-map.py,
  # NOT the CLI wrapper — the CLI rejects empty input with EXIT_USAGE,
  # while map_family() returns None for empty/non-string after the
  # strip+lookup).
  #
  # T8 — type-guard against non-string $raw. map_family() returns
  # None for non-strings (`if not isinstance(raw, str): return None`).
  # A naive `($raw // "")` here handles null, but if a malformed lens
  # emits source_family as a number / boolean / array / object, the
  # downstream `gsub` errors and the entire jq builder fails BEFORE
  # --add-findings can continue-on-error — converting "one bad
  # candidate dropped" into "Phase 1 lost the entire pool". The
  # type-guard preserves the per-candidate continue-on-error contract.
  #
  # gsub strips leading/trailing whitespace (POSIX [[:space:]] for
  # portability across Oniguruma / any future jq engine),
  # ascii_downcase normalizes case, empty input is treated as null
  # (NOT "diff-family" — surfacing an upstream lens emitting empty
  # source_family as drift in trace.md is more useful than silently
  # bucketing). Keep this table in sync with bin/source-family-map.py
  # — both readers exist by design (this one is hot-path Phase 1; the
  # helper is a one-shot for ad-hoc debugging). The drift-table
  # smoke assertion (AF-DRIFT, Section 5) catches divergence.
  def fam_canonical($raw):
    ((if ($raw | type) == "string" then $raw else "" end)
     | gsub("^[[:space:]]+|[[:space:]]+$"; "")
     | ascii_downcase) as $k |
    if   $k == "" then null
    elif $k == "diff-family"        or $k == "structural-family"
      or $k == "policy-family"      or $k == "ux-family"
      or $k == "security-family"    or $k == "holistic-family"
      or $k == "external-deep-family" or $k == "external-add-family" then $k
    elif $k == "stale-line-ref"     or $k == "stale_line_ref"
      or $k == "stale-behavior-claim" or $k == "stale_behavior_claim" then "policy-family"
    elif $k == "prompt-injection"   or $k == "prompt_injection"
      or $k == "input-validation"   or $k == "input_validation"
      or $k == "path-traversal"     or $k == "path_traversal"
      or $k == "terminal-injection" or $k == "terminal_injection" then "security-family"
    else null end;

  {
    findings: [
      .[] | . as $cand |
      ((fam_canonical($cand.source_family)) // "unknown") as $f |
      $cand + {
        source_family: $f,
        source_families: [$f],
        actionability: (if ($cand.impact_type == "correctness" or $cand.impact_type == "security") then "auto_fixable"
                       elif ($cand.impact_type == "architecture") then "report_only"
                       else "manual" end),
        validation_lane: (if $trivial then "light"
                          elif ($cand.impact_type == "correctness" or $cand.impact_type == "security") then "deep"
                          else "light" end),
        current_state: "open",
        disposition: "pending_validation",
        is_actionable: false,
        reason: null,
        confirmed_strength: null,
        score_phase3: null,
        score_phase4: null,
        score_history: [],
        validation_result: null,
        fix_attempts: [],
        introduced_in_sha: null,
        suggested_follow_up: null,
        related_parent_finding_id: null
      }
      | del(.source_family, .evidence_snippet)
    ],
    drift: [
      .[] | select(fam_canonical(.source_family) == null) |
      "lens_source_family_unknown: source=\(.sources[0] // "(unknown)") raw=\(.source_family // "(missing)") -> mapped to \"unknown\""
    ]
  }
')

findings_array=$(printf '%s' "$build_result" | jq -c '.findings')

# Phase-1 sanity check (Discussion item 2 resolution): the jq builder
# above should produce one element per input candidate. If the count
# drops here, jq dropped candidates via select() / del / null-handling
# — that's a structural bug in the jq builder, distinct from
# per-finding shape rejection downstream in --add-findings. Catches
# the silent-loss class without coupling to the helper's --expected
# infrastructure (which is designed for re-dispatch semantics that
# don't fit the add-findings shape).
expected_n=$(printf '%s' "$ided" | jq 'length')
built_n=$(printf '%s' "$findings_array" | jq 'length')
if [[ "$built_n" != "$expected_n" ]]; then
    printf 'phase_1_jq_builder_count_drop: expected=%s built=%s — jq builder dropped candidates before --add-findings\n' \
        "$expected_n" "$built_n" >> "$trace_log_path"
fi

# Audit-log unknown families to trace.md so the next mapping-table
# update surfaces from inspection rather than a silent drop.
drift_lines=$(printf '%s' "$build_result" | jq -r '.drift[]')
if [[ -n "$drift_lines" ]]; then
    printf '%s\n' "$drift_lines" >> "$trace_log_path"
fi

# Single batched write. Stdin keeps the findings-array out of any
# argv-size envelope on the helper side; the orchestrator's Bash
# command body still holds it as a shell variable, but never crosses
# the process boundary as text. Continue-on-error: rejected findings
# emit `add-findings-rejected:` lines on stderr; we drain them
# synchronously into trace.md (T1 — see below) and the orchestrator
# transcript; accepted findings commit in one atomic write.
#
# T1 — synchronous stderr capture instead of process substitution.
# Earlier draft used `2> >(tee -a "$trace_log_path" >&2)` (background
# subshell, async). That was safe for Phase 1.6's later grep (the
# pipeline drains by then) but RACED with the immediate
# `phase_1_add_findings_total_failure:` grep in this same block —
# `tee` could still be flushing while we read the count, producing
# misleading `rejected=0` tags when 50 rejections actually happened.
#
# The synchronous tempfile pattern below preserves the dual-emission
# property of the old `tee` (stderr lines visible to BOTH trace.md
# AND the orchestrator transcript) while making the post-helper grep
# deterministic. The lens-dispatch sites earlier in this fragment can
# stay on `2> >(tee ...)` because nothing reads trace.md immediately
# afterward — only this site needs the synchronous form.
stderr_capture=$(mktemp)
add_rc=0
printf '%s' "$findings_array" \
  | artifact-patch.py --path "$artifact_path" --add-findings - \
      2>"$stderr_capture" || add_rc=$?

# Drain the helper's stderr to trace.md and re-emit on stderr (so the
# orchestrator transcript still sees the per-rejection lines, matching
# the dual-emission semantics of the tee pattern used elsewhere).
if [[ -s "$stderr_capture" ]]; then
    cat "$stderr_capture" >> "$trace_log_path"
    cat "$stderr_capture" >&2
fi

if [[ "$add_rc" != "0" ]]; then
    landed_n=$(artifact-read.sh --path "$artifact_path" \
        --filter '.findings | length')
    printf 'phase_1_add_findings_failed: rc=%s landed=%s see trace.md for per-rejection detail\n' \
        "$add_rc" "$landed_n" >> "$trace_log_path"
    # Distinct loud-failure surface (R2) for the catastrophic case
    # (every candidate dropped). Phase 2 dedup's empty-pool guard
    # would also catch this, but a discrete tag in trace.md /
    # phases.jsonl makes "Phase 1 silently lost the entire pool"
    # easy to spot vs. "this was a healthy zero-finding review"
    # (e.g., docs-only PR under trivial mode).
    if [[ "$landed_n" == "0" ]]; then
        # Count rejections from the synchronous capture, NOT from
        # trace.md — both contain the same lines now, but the
        # tempfile is the deterministic source.
        rejected_count=$(grep -c '^add-findings-rejected:' "$stderr_capture" 2>/dev/null || true)
        printf 'phase_1_add_findings_total_failure: rc=%s expected=%s rejected=%s — investigate trace.md add-findings-rejected: lines\n' \
            "$add_rc" "$expected_n" "$rejected_count" \
            >> "$trace_log_path"
    fi
    # Don't bail Phase 1 here. The audit tags above + Phase 1.6's
    # summary surface the failure for the operator; if some findings
    # landed, downstream phases run on what's there.
fi

rm -f "$stderr_capture"
```

The surrounding prose in §1.5 step 4 needs three updates:

- Replace the "On non-zero exit for any single `--add-finding`, read
  the error-as-prompt..." paragraph with the new continue-on-error
  contract: rejections appear as `add-findings-rejected:` lines in
  `trace.md` with the offending id and reason; no per-candidate retry
  loop in the orchestrator. (See the "Accepted regression" section
  below for the rationale.)
- Note that `--add-finding` (singular) is still supported and used by
  Wave 2 (`fragments/05-validation.md` step 4.5) and `/adamsreview:add`
  (`commands/add.md` step 6); only the Phase 1 join site migrates here.
- Extend Phase 1.6's summary grep to surface three new structural-
  failure tags (rejection count + jq-builder count drops + total-
  failure) so systematic regressions show up in `phases.jsonl`
  alongside the existing `lens_drops` / `origin_crosscheck_skipped`
  counts:
  ```bash
  add_findings_rejected=$(grep -c '^add-findings-rejected:' "$trace_log_path" 2>/dev/null || true)
  jq_builder_count_drops=$(grep -c '^phase_1_jq_builder_count_drop:' "$trace_log_path" 2>/dev/null || true)
  add_findings_total_failures=$(grep -c '^phase_1_add_findings_total_failure:' "$trace_log_path" 2>/dev/null || true)
  ```
  Add all three to the `--summary` string. A healthy run reports
  `add_findings_rejected=0 jq_builder_count_drops=0
  add_findings_total_failures=0`. Non-zero on any of these signals a
  distinct failure class:
  - `add_findings_rejected > 0` → the helper rejected one or more
    candidates at preflight (lens or normalizer emitted a malformed
    shape). Detail in trace.md `add-findings-rejected:` lines.
  - `jq_builder_count_drops > 0` → the in-jq builder dropped
    candidates before they reached the helper (jq-template bug, not
    a per-finding shape problem). Detail in trace.md
    `phase_1_jq_builder_count_drop:` lines.
  - `add_findings_total_failures > 0` → catastrophic case: zero
    findings landed despite a non-empty pool. Detail in trace.md
    `phase_1_add_findings_total_failure:` line + rejection lines.

### 4. `CLAUDE.md` — Helper index + Batched-helper pattern

Two small edits:

- **Helper index, `artifact-patch.py` row.** Add `--add-findings` to
  the mode list with the parenthetical "(continue-on-error; single
  atomic write across the accepted batch; exit 7 = all-rejected,
  distinct from exit 1 = input/post-write invalid)" so the
  divergence from the other batched modes is documented in one place.
- **Operational rule 3 (exit codes are a contract).** Append `7=all-
  rejected (--add-findings: every input element was rejected at
  preflight; distinct from 1 so callers can branch)` to the canonical
  exit-code list.
- **"Batched-helper pattern" section.** Append a paragraph noting
  that `--add-findings` is the fourth batched mode but uses
  continue-on-error + single-atomic-write semantics because creating
  findings has different recovery requirements than mutating them.
  Future batched modes should pick the matching pattern: mutate →
  first-fail-halt + per-tuple atomic; create → continue-on-error +
  single atomic.

### 5. `test/smoke.sh` — AF-1..AF-7 + AF-DRIFT, plus PF-INT-4 update

Per the existing convention (BD-1..BD-4 covers `--apply-decisions`,
each with 2–4 assertions on shape and on-disk state), add seven
assertions under a new `AF-*` prefix, plus update the existing
`PF-INT-4` integration guard which goes stale.

- **AF-1, happy path.** Batched write of three valid findings into a
  fresh artifact; verify all three land in `findings[]`, exit 0,
  summary line shape.
- **AF-2, mixed batch (with nested-key coverage per R5).** Five
  findings where:
  - #2 carries an unknown TOP-LEVEL key (`extra_field: 1`) — exercises
    the finding-schema's `additionalProperties: false`.
  - #3 carries an unknown NESTED key (e.g.,
    `validation_result.blast_radius.extra_subkey: []`) — exercises
    `validation_result`/`blast_radius`'s nested
    `additionalProperties: false` so we know the validator catches
    drift at every depth, not just top-level.
  - #5 duplicates an id already in the artifact.
  Verify #1 and #4 land, stderr carries three `add-findings-rejected:`
  lines with correct ids and reasons (two `schema_invalid` — one
  top-level, one nested — and one `duplicate_id`), exit 0, summary
  line names skipped ids.
- **AF-3, all-bad batch.** Two findings, both schema-invalid; verify
  nothing is written, exit `EXIT_ALL_REJECTED` (7) — distinct from
  `EXIT_USAGE` (64) so a future caller can branch on "every finding
  was bad" vs. "input wasn't a JSON array." Summary line says
  "added 0 findings (skipped 2: ...)". **T6 coverage:** also assert
  stderr includes the batch-level `ERROR:` / `Action:` block from the
  required `c.err_prompt(...)` call before the summary line — proves
  the helper conforms to operational rule 4 on the all-rejected exit.
- **AF-4, stdin input.** Same as AF-1 but via `printf '%s' "$arr" |
  artifact-patch.py --add-findings -`; verify equivalent on-disk
  state. Pins the stdin code path so a future regression that argv-
  pressures the inline form is caught.
- **AF-5, defense-in-depth post-write validation (CONTINGENT — T7).**
  Codex flagged that a finding that passes `validate_finding()` but
  fails ONLY the full-artifact validator is hard to construct under
  the current schema — there is no cross-finding uniqueness or
  artifact-level invariant involving otherwise-valid finding objects.
  The post-write code path (the `_write_and_emit` defense-in-depth
  call) STAYS in the helper, but skip the smoke assertion until a
  real fixture surfaces (e.g., a future schema constraint that makes
  this case constructible). If shipping AF-5 anyway, document the
  exact fixture and don't fake one with field-level invariants the
  per-finding validator already catches.
- **AF-6, empty array.** `--add-findings '[]'` succeeds with "added 0
  findings", exit 0, no stderr. Pins the empty-input behavior.
- **AF-7, usage errors (T5).** Three sub-assertions on the
  `EXIT_USAGE` (64) paths — these are the surface a downstream caller
  hits when something upstream is wrong, and we want them stable:
  - **AF-7a:** `--add-findings '"hello"'` (parsed JSON is a string,
    not an array) → exit 64; on-disk artifact unchanged; stderr names
    "JSON array".
  - **AF-7b:** `printf 'not-json' | artifact-patch.py --add-findings
    -` (unparseable JSON) → exit 64 (via `read_json_arg()`'s existing
    handling); stderr names the parse error.
  - **AF-7c:** mode conflict — `--add-findings ... --finding-id F001`
    or `--add-findings ... --set foo=bar` → exit 64 (argparse error
    via `parser.error()`); stderr names the conflict.
- **AF-DRIFT, drift-table agreement (T3).** Iterate every key in
  `bin/source-family-map.py`'s `CANONICAL` set + `DRIFT_MAP` table;
  for each key, run both:
  - the helper CLI (`source-family-map.py --input <key>`)
  - a `jq` snippet that mirrors the in-jq `fam_canonical` table
    (extracted from the fragment so this test is the verification
    boundary, not just a mirror of the fragment)

  …and assert the outputs agree. A divergence — say, a future commit
  adds `xss-injection → security-family` to Python but forgets the
  jq table — fails this assertion immediately, regardless of whether
  trace.md ever logs the drift. Cost: ~20 lines of bash. Forecloses
  the entire two-site drift class that the in-jq inlining introduces.

  Implementation sketch:
  ```bash
  # Extract every canonical + drift key from the helper's source.
  keys=$(python3 -c "
  import sys; sys.path.insert(0, '$TOOLS')
  from source_family_map import CANONICAL, DRIFT_MAP
  for k in sorted(CANONICAL): print(k)
  for k in sorted(DRIFT_MAP): print(k)
  ")
  while IFS= read -r k; do
      py_out=$("$TOOLS/source-family-map.py" --input "$k" 2>/dev/null || echo "UNKNOWN")
      jq_out=$(printf '%s' "\"$k\"" | jq -r '
        # Inline jq table (kept in sync with fragments/01-detection.md).
        # If this gets bigger, factor into bin/fam_canonical.jq.
        def fam_canonical($raw): ... ;
        fam_canonical(.) // "UNKNOWN"
      ')
      [[ "$py_out" == "$jq_out" ]] || fail "AF-DRIFT: '$k' Py=$py_out jq=$jq_out"
  done <<< "$keys"
  ```
  Note: the jq table is duplicated between this assertion and the
  fragment. To avoid a third drift site, factor the jq function body
  into a shared file at `bin/fam_canonical.jq` and reference it from
  both the smoke test and the fragment via `jq --include-dir bin -L
  bin -r 'include "fam_canonical"; ...'` — OR just paste-duplicate
  with a comment pointing at the fragment, and accept that AF-DRIFT
  catches the meaningful case (Python ≠ jq). The latter is simpler;
  the former is the more durable design.

- **PF-INT-4 update (T11).** The existing assertion at
  `test/smoke.sh:4167-4176` greps `fragments/01-detection.md` for
  three markers: `source-family-map.py`, `canonical_family="unknown"`,
  and `lens_source_family_unknown`. After this change:
  - `canonical_family="unknown"` is **gone** (the per-call shell
    variable is replaced by in-jq canonicalization).
  - `source-family-map.py` may or may not still appear in the
    fragment (it survives in the cross-reference prose; doesn't
    survive in the active code path). Don't rely on it.
  - `lens_source_family_unknown` IS preserved (emitted by the new jq
    drift array → trace.md).

  Replace the marker triple with the post-change shape. Suggested:
  ```bash
  if grep -qF 'fam_canonical' "$DET_MD" \
      && grep -qF -- '--add-findings' "$DET_MD" \
      && grep -qF 'lens_source_family_unknown' "$DET_MD"; then
      pass "PF-INT-4: detection fragment integrates batched --add-findings + in-jq fam_canonical (escalate-not-drop)"
  else
      fail "PF-INT-4: detection fragment integration missing markers in $DET_MD"
  fi
  ```
  These markers prove (1) the in-jq canonicalization landed
  (`fam_canonical`), (2) the batched helper replaced the per-call
  loop (`--add-findings`), and (3) drift escalation still works
  (`lens_source_family_unknown`).

Each AF-* assertion verifies both stdout (summary shape) and on-disk
state (via `artifact-read.sh --filter '.findings | map(.id)'`).

## Risks and what we've done about them

**Continue-on-error could mask systematic shape regressions across
many findings.** Today's per-call loop is loud on every drop; the new
mode emits one structured stderr block per drop, which then flows into
`trace.md`. The Phase 1.6 summary grep extension above (counting
`add-findings-rejected:` lines) is the structural-failure surface — a
review where 30 of 50 candidates dropped because of a lens-output
shape change shows up there as a non-zero count, the same way
`lens_drops` and `origin_crosscheck_skipped` do today.

**One atomic write means a finding that slips past preflight kills
the whole batch.** The per-finding sub-schema (`validate_finding()`)
is the same schema the post-write full-artifact check uses for the
`findings[]` items, so the second check should rarely fire — Codex
flagged (T7) that under the current schema, constructing a finding
that passes per-finding validation but fails ONLY the full-artifact
validator is hard, because there's no cross-finding uniqueness or
artifact-level invariant for otherwise-valid findings. Keeping the
post-write call as defense-in-depth: if it ever does fire (e.g., a
future schema constraint at the artifact level), that's a preflight
bug to investigate, and `_write_and_emit`'s existing error-as-prompt
names the offending rule. AF-5 is contingent (Section 5) — added
when a real fixture surfaces.

**The orchestrator's findings-array still lives in shell.** After the
refactor, the per-candidate JSON exists only as a value inside one
shell `jq` invocation and one stdin pipe — it never crosses the
orchestrator-helper boundary as a Bash transcript entry. The cost
surface that *remains* untouched by this plan is the **lens-result
strings** in 1.4 collection: each lens sub-agent's candidate array
sits in the orchestrator's working set as in-prompt content until
Phase 1 commits. That's a separate context-cost class (working-set,
not transcript) and is what the deferred lens-scratch-file refactor
attacks. This plan deliberately addresses the smaller-but-faster-to-
land of the two surfaces; the deferred one is bigger but riskier and
gets its own plan.

**Argv-size on the orchestrator side.** The `findings_array` shell
variable is built and consumed inside one Bash call, so it never
crosses the orchestrator boundary. Stdin into the helper takes only
the literal `-` on argv. For 50 findings × ~500 bytes each that's a
~25 KB shell-internal value; for pathological cases (200 findings ×
1 KB), bumping to a scratch-file pipe (`< $scratch_dir/phase1.json`)
is a one-line fragment edit if needed.

**Backward compatibility.** `--add-finding` (singular) stays
unchanged. The two remaining callers (`fragments/05-validation.md`
Wave 2; `commands/add.md` step 6) keep working without edits. The
new mode is purely additive.

## Accepted regression: the per-candidate retry-once goes away

The current fragment carries a per-candidate recovery directive: "On
non-zero exit for any single `--add-finding`, read the error-as-prompt
(it names the offending field and id), adjust your `jq` build, retry
once. On second failure, log the finding id to `trace.md` and drop
it." Under the new mode, the orchestrator no longer sees per-finding
errors as separate Bash exits — it sees one batched response with
structured stderr blocks, and there's no opening for "adjust the jq
build and retry."

In practice this is a small loss. The retry was designed for a
specific failure mode: a malformed `jq` build that emitted a finding
with a missing required field, where re-emitting from a corrected jq
template would succeed. That failure mode requires the orchestrator
to be the one with a buggy jq template, which is rare on a fragment
that's been stable for several stages. The much more common drop
class is **upstream lens drift** — the lens emitted a candidate with
a bad shape — and for that, no retry helps; the candidate is just
bad. Trading a rarely-effective retry for the orchestrator-context
win is the right call, but worth naming explicitly so a future
regression doesn't surprise anyone.

## Out of scope (deferred)

- **Wave 2 site (`fragments/05-validation.md` step 4.5) — defer
  indefinitely; the empirics make this essentially free already.**
  Wave 2 also loops `--add-finding` per related candidate, so the
  loop *shape* is identical to Phase 1's. But the operational data
  is the load-bearing fact here: across **44 reviews on file**, Wave
  2 produced findings in only **3 reviews (~7%)** and never spawned
  more than **3 findings** in any single run (counts: 1, 1, 3).
  Expected per-review orchestrator-context savings from migrating:
  ~0 transcript pairs (peak ~3, mode 0).

  *Why so quiet?* Two structural gates choke Wave 2 input. (a) Wave 2
  only fires off Wave 1 *deep-lane confirms* that emit
  `related_candidates_to_investigate[]`; reviews dominated by
  light-lane work or with few correctness/security confirms produce
  zero relateds. (b) The dedup-against-existing step at the top of
  §4.5 absorbs most surviving relateds — when a Wave 1 validator
  flagged an adjacent issue, that issue is usually *already a Phase
  1 finding* and gets dropped before Wave 2 begins. The "dedup
  efficiency" is doing more work than the deferral text earlier
  acknowledged.

  *Migration would not be free even if cost surfaced.* The helper
  is unchanged (`--add-findings` handles the array regardless of
  origin), but the fragment-side jq builder is genuinely different
  from Phase 1's: `related_parent_finding_id` varies per row (vs.
  Phase 1's hardcoded null), the dedup output must carry parent IDs
  through to the build step (vs. Phase 1's loose dedup), and ID
  assignment requires `assign-finding-ids.sh --start-from F<next>`
  (vs. Phase 1's start-from-F001). Doable but real fragment work
  with no observed payoff.

  *Re-evaluation trigger.* Defer indefinitely. Revisit only if (i)
  the §4.2 step 7 validator prompt is loosened (e.g., dropping the
  "even half-confident ones" qualifier increases related-emission
  rates), (ii) wave-cap is raised above 2, or (iii) a single review
  is observed with Wave 2 ≥ 10. Until then this is a non-cost.

- **`/adamsreview:add` site (`commands/add.md` step 6).** Same loop
  shape, but unlike Wave 2 the candidate count is **not bounded** —
  paste-mode and structured-mode builders can emit any number of
  findings, and the user-facing /ultrareview pasteback this command
  exists to absorb is exactly the kind of input where N can hit 20+.
  So the cost case is real (closer to Phase 1's than to Wave 2's).
  The reason for deferral is *scope-complexity*: `/adamsreview:add`
  has paste-mode and structured-mode candidate builders, an override
  re-assertion, and a dedup gate that all interleave with the add
  loop. Migrating it cleanly needs separate analysis (the surrounding
  steps 1–5 don't actually touch step 6 — `/adamsreview:add` step 6
  itself is structurally simpler than Wave 2: no parent-id, no
  source-family canonicalization — but the *invariant* analysis of
  how dedup interacts with the override re-assertion needs more
  thought than this plan gave it). When that migration happens it's
  the natural place to evaluate adding a helper-side `--expected N`
  guard with proper re-dispatch semantics (see "Open question
  (resolved)" — Phase 1's silent-loss class is already covered by a
  fragment-side count check that doesn't need helper changes).
- **Lens scratch-file refactor.** Have lens sub-agents write their
  candidate arrays to `$scratch_dir/lens_<n>.json` instead of
  returning them in the response body. Eliminates per-lens result
  blobs from the orchestrator's working set entirely. Independent of
  this plan; touches every lens prompt and the §1.4 collection
  contract. Bigger orchestrator-context win, but bigger blast radius.
- **Pushing the schema-shape jq build into the helper.** The
  "maximum version." Bigger orchestrator-context win still, but pulls
  schema-shape logic out of the grep-visible fragment into Python.
  Trade-off worth its own plan if the in-jq version doesn't deliver
  enough relief.

## Testing plan

1. `test/smoke.sh` — AF-1 through AF-4, AF-6, AF-7 (a/b/c), AF-DRIFT,
   plus the PF-INT-4 marker-triple update (Section 5). AF-5 is
   contingent on a real fixture surfacing — skipped for now. Each
   assertion verifies both stdout (summary shape) and on-disk state.
2. Manual end-to-end: run `/adamsreview:review` against a small
   fixture PR with 5–10 expected findings, confirm:
   - One Bash invocation in the trace at §1.5 step 4 instead of N.
   - `artifact.findings[]` matches what the pre-batch loop would have
     produced (compare against a recent review's artifact for the
     same fixture).
   - `phases.jsonl` Phase 1 record's count matches and all three new
     audit counters are present and zero on a healthy run:
     `add_findings_rejected=0`, `jq_builder_count_drops=0`,
     `add_findings_total_failures=0`.
3. Manual fault-injection (preflight rejection path): deliberately
   mutate one candidate in a fresh review's `$ided` array to be
   schema-invalid (e.g. `line_range: "bad"`); re-run the join step;
   confirm the rest of the batch lands, `trace.md` carries the
   `add-findings-rejected:` line for the mutated candidate, and
   Phase 1.6 reports `add_findings_rejected=1`.
4. Manual drift-injection (canonicalization fall-through):
   rename one candidate's `source_family` to a value the in-jq table
   doesn't know (e.g. `"made-up-family"`); confirm the finding lands
   with `source_family: "unknown"` and `trace.md` carries the
   `lens_source_family_unknown:` line.
5. Manual fault-injection (jq-builder count drop path): introduce a
   spurious `select(.id != "F003")` in a temporary copy of the jq
   builder; confirm `phase_1_jq_builder_count_drop:` lines fire,
   Phase 1.6 reports `jq_builder_count_drops=1`, and the candidate
   that survived rejection still lands. Pins the fragment-side
   sanity check from Discussion item 2.
6. Manual fault-injection (total-failure path): make every candidate
   in `$ided` schema-invalid; confirm the helper exits 7
   (`EXIT_ALL_REJECTED`), `landed_n=0`, `phase_1_add_findings_failed:`
   AND `phase_1_add_findings_total_failure:` BOTH appear in
   trace.md, Phase 1.6 reports `add_findings_total_failures=1`, and
   Phase 2's empty-pool guard fires downstream.
7. Performance measurement (per N5): time the full Phase 1 join step
   on a recent review's candidate set before vs. after this change
   (one fixture, repeated 3×). Record the orchestrator-roundtrip
   savings (transcript pair count: N → 1) and the helper-side
   wall-clock delta. The orchestrator-context win is unambiguous;
   wall-clock should be reported as measured, not estimated, in the
   PR description.

## Sequencing

The work is small enough to land in one PR but breaks naturally into
four commits:

1. `bin/_common.py`: add `EXIT_ALL_REJECTED` constant,
   `finding_validator()`, and `validate_finding(finding, validator)`.
   (No `finding_property_keys()` — see T2.)
2. `bin/artifact-patch.py`: add `--add-findings` mode + CLI plumbing
   (slot dispatch immediately after `--add-finding` singular in
   `main()`). Three CLI-text spots (T4): top-of-file module docstring,
   `build_parser()` entry, `parser.error("no mode selected ...")`
   string. Includes the batch-level `c.err_prompt(...)` on the
   all-rejected path (T6) and the corrected exit-code policy in the
   helper docstring (T7).
3. `test/smoke.sh`: AF-1..AF-4, AF-6, AF-7 (a/b/c), AF-DRIFT
   (T3+T5+T6 coverage). AF-5 is contingent — defer until a real
   defense-in-depth fixture surfaces (T7 / Codex finding 7).
4. `fragments/01-detection.md` + `bin/source-family-map.py` (one-line
   docstring cross-reference) + `CLAUDE.md` + `test/smoke.sh`
   (PF-INT-4 update): switch the caller to the new mode (with
   type-guarded in-jq family canonicalization per T8, synchronous
   stderr capture per T1, count-mismatch check, total-failure tag,
   and explicit single-Bash-invocation note per T9), update the §1
   overview prose at fragment-top (T10), update PF-INT-4's marker
   triple (T11), update CLAUDE.md (helper index, op rule 3 for the
   new exit code, batched-helper pattern paragraph).

Commits 1–3 are pure additions — the new mode is unused until commit
4 — so they could ship without commit 4 if needed. Commit 4 is the
one that changes Phase 1's behavior in the wild. Run
`test/smoke.sh` after each commit to confirm baseline assertions
stay green; the existing PT-* / OC-* / etc. families don't depend on
the new mode but exercise overlapping helper plumbing
(`_load_validator`, `atomic_write`, `_write_and_emit`). Commit 4
specifically must keep PF-INT-4 green — its marker-triple update is
folded into commit 4, not commit 3, because the markers it now looks
for only land when the fragment is migrated.

## Open question (resolved)

**Should `--add-findings` accept an `--expected N` guard analogous to
`--apply-decisions`?** Resolved: no for the helper, yes-but-different
for the caller. Phase 1's silent-loss class (jq builder dropped
candidates before they reached the helper) is now caught by a
fragment-side count check (`expected_n` vs. `built_n`, with the
`phase_1_jq_builder_count_drop:` audit tag) — see Section 3 bash
block. That covers the Phase 1 risk without coupling to the helper's
`--expected` infrastructure.

The wrinkle that drove the deferral: `--apply-decisions` uses
`--expected` as a re-dispatch signal. Deep lane: re-dispatch one
Agent per missing candidate. Light lane: re-dispatch the chunk for
the missing ids. For `--add-findings`, a count mismatch means the
input array itself is short — there's no equivalent re-dispatch
recovery, just "log the drop and proceed with what arrived." That's
better expressed as a fragment-side audit line than as a helper
exit-code branch (which would force the helper to define recovery
semantics that don't fit the failure mode).

The `/adamsreview:add` migration may still want `--expected` later
(its candidate count is knowable from the upstream paste/structured
builders), and adding it then is forward-compatible — callers that
omit `--expected` see no behavior change. Defer the helper-side flag
until the first caller has a real re-dispatch story to tell.
