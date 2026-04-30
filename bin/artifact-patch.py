#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["jsonschema"]
# ///
"""artifact-patch.py — canonical writer for artifact.json (DESIGN §8.2, §21.2).

Modes (CLI flags; mutually exclusive):
  --init <seed>             create fresh artifact at --path
  --add-finding <finding>   append a new finding to findings[]
  --add-findings <array>    Phase 1 batched: append a JSON array of new
                            findings in one atomic write. Continue-on-
                            error: malformed individual findings are
                            logged on stderr (`add-findings-rejected:`
                            lines, one per drop) and skipped; the rest
                            of the batch still commits. Exit codes: 0
                            (≥1 accepted), 7 = EXIT_ALL_REJECTED (every
                            input rejected at preflight; distinct from
                            1 = post-write validation failed), 64 =
                            input wasn't a JSON array / mode conflict.
  --delete-finding FXXX     remove a finding by id (used by Phase 2 dedup)
  --apply-decisions <array> apply a batch of Phase-4 decision tuples in one
                            call (DESIGN §13.1, §21.2; Stage 2.5.B). Input
                            is a JSON array of {id, score_phase4, decision,
                            actionability, validation_result?, reason?,
                            confirmed_strength?, related_parent_finding_id?}.
                            The helper derives disposition per §13.1 and
                            writes validation_result only for confirmed-band
                            tuples. Per-tuple atomic write + halt on first
                            failure (preceding tuples stay committed).
                            Pair with --expected N to reject under-sized
                            batches (one tuple per dispatched candidate;
                            deep-lane: one Opus per candidate; light-lane:
                            each chunk-agent must return one tuple per
                            owned finding).
  --apply-fix-start <array> Stage 3: bulk open→attempted transition at the
                            start of Phase 8. Input is a JSON array of
                            {id, run_id}. Per-tuple atomic + first-failure
                            halts. `run_id` is carried in error messages so
                            an interrupted batch is locatable in trace.md;
                            the run_id itself isn't persisted on findings
                            until Phase 9d (via --apply-fix-outcomes).
  --apply-fix-outcomes <array>  Stage 3: Phase 9d state transitions +
                            fix_attempt append in one call. Input is a JSON
                            array of {id, run_id, fix_group_id, input_sha,
                            output_sha, phase_9_outcome, timestamp,
                            phase_9_finding?, revised_fix_proposal?}. The
                            helper maps phase_9_outcome to the §13.1 Phase-9
                            disposition (verified→resolved, partial→partial,
                            regression→regression) and appends the attempt.
                            phase_9_outcome=null (overlap-abort / §4 Phase
                            9.pre) leaves current_state at attempted and
                            only appends the fix_attempt — the next run's
                            leftover-attempted hard abort catches the user.
  --set field=value         mutate a scalar field (repeatable). With
                            --finding-id, targets a finding; without,
                            targets top-level artifact fields.
  --set-json field=<json-or-@file>  mutate a structured (array/object)
                            field (repeatable). Same --finding-id
                            targeting as --set; separate whitelist of
                            allowed fields (arrays/objects only).
  --append-fix-attempt <json>  append an entry to a finding's fix_attempts[]
                               (requires --finding-id). Combinable with
                               --set in a single call (DESIGN §26 worked
                               example: set current_state=resolved and
                               append the attempt in one patch).

### --set semantics

Field allowlist (see SETTABLE_FINDING_FIELDS / SETTABLE_ARTIFACT_FIELDS):
non-listed fields are rejected with an error-as-prompt listing the
allowed names. Arrays and objects are never set via --set (use --init,
--add-finding, or mode-specific flags).

Value parsing: JSON-literal first, string fallback. So `--set x=null`,
`--set x=85`, `--set x=true` produce the JSON value; `--set x=foo`
produces the string "foo". A user who actually means the string "true"
passes `--set x='"true"'` (explicit JSON quotes).

Coupling rules (DESIGN §5.2.1, §21.2):
- `disposition` and `is_actionable` stay in lockstep. Setting disposition
  auto-derives is_actionable; setting both in the same call requires
  they agree.
- `current_state=resolved` iff `disposition=resolved`. The script checks
  the effective post-patch state in both directions and rejects any
  disagreement.
- State transitions follow the §5.3 whitelist. Invalid transitions exit
  with code 2 and list the valid next states.
- Setting `score_phase3` / `score_phase4` auto-appends the corresponding
  entry to `score_history` (which is otherwise append-only).

JSON arguments (seed, finding payload, etc.) accept three forms:
  inline     --init '{"schema_version":1,...}'
  file       --init @/path/to/seed.json
  stdin      --init -

Every write validates the full artifact against schema-v1.json and
goes through atomic tmp+rename. Non-zero exits emit error-as-prompt
blocks to stderr per DESIGN §8.6.
"""

import argparse
import copy
import difflib
import json
import os
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path

# _common.py lives next to this file. uv run --script prepends our dir to sys.path.
sys.path.insert(0, str(Path(__file__).parent))
import _common as c  # noqa: E402


# ----- Input parsing -----------------------------------------------------

def read_json_arg(value, flag_name):
    """Parse a JSON value from inline string, @<file>, or - (stdin).

    Returns the parsed value. On failure, emits an error-as-prompt and
    raises SystemExit with the usage code.
    """
    raw = None
    source = None
    try:
        if value == "-":
            raw = sys.stdin.read()
            source = "<stdin>"
        elif value.startswith("@"):
            path = value[1:]
            with open(path) as f:
                raw = f.read()
            source = path
        else:
            raw = value
            source = "<inline>"
        return json.loads(raw)
    except OSError as e:
        c.err_prompt(
            f"could not read {flag_name} from {source}: {e}",
            action=f"pass {flag_name} as inline JSON, @<file>, or - for stdin."
        )
        sys.exit(c.EXIT_USAGE)
    except json.JSONDecodeError as e:
        preview = (raw or "")[:80]
        c.err_prompt(
            f"{flag_name} value is not valid JSON: {e.msg} (line {e.lineno}, col {e.colno})",
            context=f"Input source: {source}; preview: {preview!r}",
            action=f"pass {flag_name} as a JSON value (inline, @<file>, or - for stdin)."
        )
        sys.exit(c.EXIT_USAGE)


# ----- Modes -------------------------------------------------------------

def cmd_init(args):
    """Create a fresh artifact from a seed doc (§8.2)."""
    seed = read_json_arg(args.init, "--init")

    if not isinstance(seed, dict):
        c.err_prompt(
            f"--init expects a JSON object, got {type(seed).__name__}",
            action="the seed must be a top-level artifact object (DESIGN §6)."
        )
        return c.EXIT_USAGE

    # Server-authoritative defaults: fill only when absent so callers can
    # pin these fields explicitly (useful for deterministic tests).
    seed.setdefault("schema_version", 1)
    seed.setdefault("generated_at", datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))

    errors = c.validate(seed)
    if errors:
        shown = errors[:10]
        overflow = [f"  (+{len(errors) - 10} more)"] if len(errors) > 10 else []
        c.err_prompt(
            f"init seed is invalid ({len(errors)} schema violation(s))",
            context=["  " + e for e in shown] + overflow,
            action="fix the seed to satisfy schema-v1.json (DESIGN §6), then re-run."
        )
        return c.EXIT_VALIDATION

    # If the target file exists, load its content for the dry-run diff
    # base. A failed load doesn't fail the init — we just show the full
    # new doc as an all-additions diff.
    before = None
    if args.dry_run and os.path.exists(args.path):
        try:
            before = c.read_json(args.path)
        except (OSError, json.JSONDecodeError):
            before = None

    return _write_and_emit(args.path, seed, dry_run=args.dry_run, before=before)


def _load_or_fail(path):
    """Read the artifact at `path`, or emit an error-as-prompt and exit."""
    try:
        return c.read_json(path)
    except FileNotFoundError:
        c.err_prompt(
            f"artifact not found at {path}",
            action="run `artifact-patch.py --init ...` first, or pass the correct --path."
        )
        sys.exit(c.EXIT_VALIDATION)
    except json.JSONDecodeError as e:
        c.err_prompt(
            f"artifact at {path} is not valid JSON: {e.msg} (line {e.lineno}, col {e.colno})",
            action="the on-disk file is corrupted — restore from git or re-run --init."
        )
        sys.exit(c.EXIT_VALIDATION)


def _write_and_emit(path, artifact, dry_run=False, before=None, silent=False):
    """Common write tail: bump generated_at, validate, then either write or print a diff.

    With dry_run=True:
      - Invalid result: exit EXIT_DRY_RUN_INVALID (3) with error-as-prompt.
      - Valid result: print unified diff to stdout, log "(dry-run: no write)"
        to stderr, exit EXIT_OK.
    With dry_run=False:
      - Invalid result: exit EXIT_VALIDATION (1) (post-patch invariant break
        shouldn't normally happen if the mode's pre-checks are correct).
      - Valid result: atomic tmp+rename, log "wrote <path>" to stdout unless
        silent=True (used by --apply-decisions batch loop so the orchestrator
        sees one summary line, not N per-tuple lines).
    """
    artifact["generated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    errors = c.validate(artifact)
    if errors:
        shown = errors[:10]
        overflow = [f"  (+{len(errors) - 10} more)"] if len(errors) > 10 else []
        c.err_prompt(
            f"patched artifact is invalid ({len(errors)} schema violation(s))",
            context=["  " + e for e in shown] + overflow,
            action=("--dry-run caught this before writing; fix the input."
                    if dry_run
                    else "this indicates a bug in the patch mode or a malformed input value.")
        )
        return c.EXIT_DRY_RUN_INVALID if dry_run else c.EXIT_VALIDATION

    if dry_run:
        before_lines = (
            json.dumps(before, indent=2, sort_keys=True).splitlines(keepends=True)
            if before is not None
            else []
        )
        after_lines = json.dumps(artifact, indent=2, sort_keys=True).splitlines(keepends=True)
        diff = difflib.unified_diff(
            before_lines, after_lines,
            fromfile=f"{path} (before)",
            tofile=f"{path} (after)",
        )
        sys.stdout.writelines(diff)
        sys.stdout.flush()
        if before_lines == after_lines:
            print("(dry-run: no changes)", file=sys.stderr)
        else:
            print("(dry-run: no write)", file=sys.stderr)
        return c.EXIT_OK

    c.atomic_write(path, artifact)
    if not silent:
        print(f"wrote {path}")
    return c.EXIT_OK


# ----- --set allowlist + value parsing ----------------------------------

SETTABLE_FINDING_FIELDS = frozenset({
    "impact_type",
    "origin",
    "origin_confidence",
    "actionability",
    "validation_lane",
    "current_state",
    "disposition",
    "is_actionable",
    "reason",
    "confirmed_strength",
    "score_phase3",
    "score_phase4",
    "introduced_in_sha",
    "suggested_follow_up",
    "related_parent_finding_id",
})

SETTABLE_ARTIFACT_FIELDS = frozenset({
    "comment_id",
    "trivial_mode",
    "pr_state",
    "pr_number",
})

# ----- --set-json: structured (array/object) fields ---------------------
#
# Separate whitelist from --set (which is scalar-only). --set-json accepts
# values as inline JSON, @<file> for file-read, or - for stdin. Same
# --finding-id targeting: with --finding-id, matches FINDING fields; without,
# matches ARTIFACT fields. fix_attempts is intentionally not here — that's
# append-only via --append-fix-attempt.

JSON_SETTABLE_FINDING_FIELDS = frozenset({
    "sources",
    "source_families",
    "validation_result",
    "human_confirmation",
    # score_history is intentionally NOT here — it's append-only, driven
    # automatically by --set score_phase3/score_phase4 (see
    # _apply_finding_set). Bypassing that would let callers overwrite
    # history, which defeats the audit trail.
})

JSON_SETTABLE_ARTIFACT_FIELDS = frozenset({
    "cross_cutting_groups",
    "subagent_tokens",
    "orchestrator_tokens",
    "metrics",
    "reviewer_sources",
})


def parse_set_pair(pair):
    """Parse one '--set K=V' pair into (key, value).

    Value uses JSON-literal-first parsing (so null/true/false/numbers
    become native Python types) with string fallback for bare words.
    Raises SystemExit(EXIT_USAGE) on malformed pair.
    """
    if "=" not in pair:
        c.err_prompt(
            f"--set expects 'field=value', got '{pair}'",
            action="use --set field=value; use --set twice (or more) for multiple fields."
        )
        sys.exit(c.EXIT_USAGE)
    key, _, raw = pair.partition("=")
    key = key.strip()
    if not key:
        c.err_prompt(
            f"--set has empty field name in '{pair}'",
            action="use --set field=value."
        )
        sys.exit(c.EXIT_USAGE)
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        value = raw
    return key, value


def cmd_add_finding(args):
    """Append a new finding to findings[] (§8.2)."""
    finding = read_json_arg(args.add_finding, "--add-finding")

    if not isinstance(finding, dict):
        c.err_prompt(
            f"--add-finding expects a JSON object, got {type(finding).__name__}",
            action="pass a finding object matching DESIGN §6."
        )
        return c.EXIT_USAGE

    artifact = _load_or_fail(args.path)
    before = copy.deepcopy(artifact) if args.dry_run else None

    existing_ids = {f.get("id") for f in artifact.get("findings", [])}
    new_id = finding.get("id")
    if new_id in existing_ids:
        c.err_prompt(
            f"finding id '{new_id}' already exists in {args.path}",
            valid_values=f"existing ids: {sorted(existing_ids)}",
            action="use --set to mutate an existing finding, or pick a fresh id."
        )
        return c.EXIT_VALIDATION

    artifact.setdefault("findings", []).append(finding)
    return _write_and_emit(args.path, artifact, dry_run=args.dry_run, before=before)


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
      - 64      : EXIT_USAGE — malformed input up front. Three pathways
                  share this: (a) `read_json_arg()` already exits 64
                  when stdin / @file / inline isn't parseable JSON;
                  (b) this mode emits 64 when the parsed value isn't a
                  JSON array; (c) mode-vs-non-mode-flag conflict
                  (--add-findings combined with --set / --set-json /
                  --append-fix-attempt / --finding-id) handled below
                  via c.err_prompt + return c.EXIT_USAGE, plus
                  --add-findings + --dry-run (currently rejected).
      - 2       : argparse mutex-group violation — mode-vs-mode
                  conflicts (e.g., --add-findings + --delete-finding)
                  are caught by the parser's mutually-exclusive group
                  before main() runs and exit with argparse's default
                  code 2. Behavior matches every other mode in this
                  script; documented here so the contract isn't
                  mistakenly read as "all conflicts → 64."

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


def _find_finding(artifact, finding_id):
    """Return the finding dict for `finding_id`, or emit + sys.exit on miss."""
    for f in artifact.get("findings", []):
        if f.get("id") == finding_id:
            return f
    existing = [f.get("id") for f in artifact.get("findings", [])]
    c.err_prompt(
        f"no finding with id '{finding_id}' in {artifact.get('review_id', '(unknown review)')}",
        valid_values=f"existing ids: {existing}" if existing else "no findings in this artifact",
        did_you_mean=c.suggest(finding_id, existing),
        action="check --finding-id, or add the finding with --add-finding first."
    )
    sys.exit(c.EXIT_VALIDATION)


def _apply_finding_set(finding, pairs):
    """Apply --set pairs to a finding in-place, enforcing coupling rules.

    Returns (applied_keys_set, transition_error_or_None). On coupling or
    transition failures, emits error-as-prompt and sys.exit with the
    appropriate code; on other schema problems, returns normally and the
    downstream schema validation catches them.
    """
    pair_map = {k: v for k, v in pairs}
    applied_keys = set()

    # Reject non-settable fields up front.
    bad_keys = [k for k in pair_map if k not in SETTABLE_FINDING_FIELDS]
    if bad_keys:
        c.err_prompt(
            f"--set cannot touch finding field(s): {bad_keys}",
            valid_values=sorted(SETTABLE_FINDING_FIELDS),
            did_you_mean=c.suggest(bad_keys[0], SETTABLE_FINDING_FIELDS),
            action="immutable fields (id, file, claim, sources, line_range) cannot be patched; append-only fields use --append-fix-attempt or dedicated flags."
        )
        sys.exit(c.EXIT_VALIDATION)

    # 1) State transition check (§5.3).
    if "current_state" in pair_map:
        before = finding.get("current_state")
        requested = pair_map["current_state"]
        if requested != before:
            allowed = c.transitions_from(before)
            if requested not in allowed:
                if requested not in c.CURRENT_STATE_VALUES:
                    # True typo — suggest the closest real enum and then
                    # a valid transition target from the current state.
                    did_you_mean = c.suggest(requested, c.CURRENT_STATE_VALUES)
                else:
                    # Not a typo — just not a valid next state. Skip the
                    # "did you mean" line since the bad value is spelled
                    # correctly; the valid-values line already points the
                    # caller at the allowed targets.
                    did_you_mean = None
                c.err_prompt(
                    f"invalid transition from '{before}' to '{requested}' for finding {finding.get('id')}",
                    valid_values=(sorted(allowed) or ["(none — terminal state)"]),
                    did_you_mean=did_you_mean,
                    action=("a finding must be attempted (Phase 8) before it can be resolved"
                            if before == "open" and requested == "resolved"
                            else "see DESIGN §5.3 for the valid state transitions.")
                )
                sys.exit(c.EXIT_INVALID_TRANSITION)

    # 2) Disposition / is_actionable coupling (§21.2).
    if "disposition" in pair_map:
        derived = c.derive_is_actionable(pair_map["disposition"])
        if "is_actionable" in pair_map:
            if pair_map["is_actionable"] != derived:
                c.err_prompt(
                    f"is_actionable={pair_map['is_actionable']} contradicts disposition='{pair_map['disposition']}' (derived: {derived})",
                    context=f"is_actionable is derived: true iff disposition ∈ {{confirmed_mechanical, partial, regression}}. See DESIGN §5.2.1.",
                    action="omit --set is_actionable; the script will derive it from disposition."
                )
                sys.exit(c.EXIT_VALIDATION)
        else:
            pair_map["is_actionable"] = derived
    elif "is_actionable" in pair_map:
        current_disp = finding.get("disposition")
        derived = c.derive_is_actionable(current_disp)
        if pair_map["is_actionable"] != derived:
            c.err_prompt(
                f"is_actionable={pair_map['is_actionable']} contradicts existing disposition='{current_disp}' (derived: {derived})",
                context="to change is_actionable, --set disposition instead; the script will derive is_actionable from it.",
                action="pick a compatible disposition (see DESIGN §5.2.1 table)."
            )
            sys.exit(c.EXIT_VALIDATION)

    # 3) current_state ↔ disposition=resolved coupling (§5.2.1 invariants).
    effective_state = pair_map.get("current_state", finding.get("current_state"))
    effective_disp = pair_map.get("disposition", finding.get("disposition"))
    if (effective_state == "resolved") != (effective_disp == "resolved"):
        c.err_prompt(
            f"current_state='{effective_state}' and disposition='{effective_disp}' disagree (resolved coupling)",
            context="DESIGN §5.2.1: current_state=='resolved' ⇔ disposition=='resolved'. Set both, or neither.",
            action="use --set current_state=resolved --set disposition=resolved in the same call."
        )
        sys.exit(c.EXIT_VALIDATION)

    # 4) Apply scalar sets.
    for key, value in pair_map.items():
        finding[key] = value
        applied_keys.add(key)

    # 5) score sync: score_phase3/4 mirrors into score_history append-only.
    hist = finding.setdefault("score_history", [])
    if "score_phase3" in pair_map and pair_map["score_phase3"] is not None:
        hist.append({"phase": "phase_3", "score": pair_map["score_phase3"]})
    if "score_phase4" in pair_map and pair_map["score_phase4"] is not None:
        hist.append({"phase": "phase_4", "score": pair_map["score_phase4"]})

    return applied_keys


def _apply_artifact_set(artifact, pairs):
    """Apply --set pairs to the top-level artifact (no --finding-id case)."""
    pair_map = {k: v for k, v in pairs}
    bad_keys = [k for k in pair_map if k not in SETTABLE_ARTIFACT_FIELDS]
    if bad_keys:
        c.err_prompt(
            f"--set cannot touch top-level field(s): {bad_keys}",
            valid_values=sorted(SETTABLE_ARTIFACT_FIELDS),
            did_you_mean=c.suggest(bad_keys[0], SETTABLE_ARTIFACT_FIELDS),
            action="finding-level fields require --finding-id; immutable fields cannot be patched."
        )
        sys.exit(c.EXIT_VALIDATION)
    for key, value in pair_map.items():
        artifact[key] = value
    return set(pair_map.keys())


def parse_set_json_pair(pair):
    """Parse one '--set-json K=V' pair into (key, parsed_value).

    Value parsing: inline JSON, @<file> for file-read, or '-' for stdin.
    Raises SystemExit on malformed pair or unparseable JSON.
    """
    if "=" not in pair:
        c.err_prompt(
            f"--set-json expects 'field=<json-or-@file>', got '{pair}'",
            action="use --set-json field=<inline-json>, field=@<path>, or field=-"
        )
        sys.exit(c.EXIT_USAGE)
    key, _, raw = pair.partition("=")
    key = key.strip()
    if not key:
        c.err_prompt(
            f"--set-json has empty field name in '{pair}'",
            action="use --set-json field=value."
        )
        sys.exit(c.EXIT_USAGE)

    value = read_json_arg(raw, f"--set-json {key}")
    return key, value


def _apply_finding_set_json(finding, pairs):
    """Apply --set-json pairs to a finding in-place."""
    pair_map = {k: v for k, v in pairs}
    bad_keys = [k for k in pair_map if k not in JSON_SETTABLE_FINDING_FIELDS]
    if bad_keys:
        c.err_prompt(
            f"--set-json cannot touch finding field(s): {bad_keys}",
            valid_values=sorted(JSON_SETTABLE_FINDING_FIELDS),
            did_you_mean=c.suggest(bad_keys[0], JSON_SETTABLE_FINDING_FIELDS),
            action="scalar fields use --set; fix_attempts is append-only via --append-fix-attempt; immutable fields (id/file/claim/line_range) cannot be patched."
        )
        sys.exit(c.EXIT_VALIDATION)
    for key, value in pair_map.items():
        finding[key] = value
    return set(pair_map.keys())


def _apply_artifact_set_json(artifact, pairs):
    """Apply --set-json pairs to the top-level artifact."""
    pair_map = {k: v for k, v in pairs}
    bad_keys = [k for k in pair_map if k not in JSON_SETTABLE_ARTIFACT_FIELDS]
    if bad_keys:
        c.err_prompt(
            f"--set-json cannot touch top-level field(s): {bad_keys}",
            valid_values=sorted(JSON_SETTABLE_ARTIFACT_FIELDS),
            did_you_mean=c.suggest(bad_keys[0], JSON_SETTABLE_ARTIFACT_FIELDS),
            action="finding-level fields require --finding-id; immutable fields cannot be patched."
        )
        sys.exit(c.EXIT_VALIDATION)
    for key, value in pair_map.items():
        artifact[key] = value
    return set(pair_map.keys())


def cmd_delete_finding(args):
    """Remove a finding by id (used by Phase 2 dedup)."""
    finding_id = args.delete_finding
    artifact = _load_or_fail(args.path)
    before = copy.deepcopy(artifact) if args.dry_run else None

    findings = artifact.get("findings", [])
    existing_ids = [f.get("id") for f in findings]
    if finding_id not in existing_ids:
        c.err_prompt(
            f"no finding with id '{finding_id}' to delete in {artifact.get('review_id', '(unknown review)')}",
            valid_values=f"existing ids: {existing_ids}" if existing_ids else "no findings in this artifact",
            did_you_mean=c.suggest(finding_id, existing_ids),
            action="check the id spelling; use --add-finding to add, --set to mutate."
        )
        return c.EXIT_VALIDATION

    artifact["findings"] = [f for f in findings if f.get("id") != finding_id]
    return _write_and_emit(args.path, artifact, dry_run=args.dry_run, before=before)


# ----- --apply-decisions: Phase-4 batch application (DESIGN §13.1, §21.2) ---
#
# Input is a JSON array of decision tuples. Each tuple has one finding's Phase-4
# outcome: score_phase4 (number or null), optional decision/actionability,
# optional validation_result (written only for confirmed-band dispositions),
# optional reason / confirmed_strength / related_parent_finding_id.
#
# Derivation table (§13.1 Phase 4):
#   score_phase4 == null → disposition=uncertain (parse-failure fallback,
#                          see 05-validation step 4.4 prose)
#   score_phase4 < 45    → disposition=disproven
#   score_phase4 45-59   → disposition=uncertain
#   score_phase4 >= 60   → needs actionability:
#                            auto_fixable → confirmed_mechanical
#                            manual       → confirmed_manual
#                            report_only  → confirmed_report
#                          confirmed_strength: moderate (60-74) / strong (75+)
#
# The score-wins-over-decision rule from 05-validation applies implicitly:
# we derive disposition from score + actionability, ignoring the tuple's
# `decision` field (which exists so the JSON is auditable but isn't
# authoritative). A validator returning decision=disproven, score=70 with
# actionability=auto_fixable routes to confirmed_mechanical.
#
# per-tuple atomic writes + first-failure-halts (plan §5.2): if tuple N
# is invalid, tuples 0..N-1 have been written to disk; caller re-invokes
# with the remainder.

ALLOWED_DECISION_TUPLE_KEYS = frozenset({
    "id",
    "score_phase4",
    "decision",                    # audit-only; derivation uses score + actionability
    "actionability",
    "validation_result",
    "reason",
    "confirmed_strength",          # tuple override for the derived strength
    "related_parent_finding_id",
})

CONFIRMED_BAND = frozenset({"confirmed_mechanical", "confirmed_manual", "confirmed_report"})

_ACTIONABILITY_TO_DISPOSITION = {
    "auto_fixable": "confirmed_mechanical",
    "manual": "confirmed_manual",
    "report_only": "confirmed_report",
}


def _derive_phase4_disposition(tup, idx):
    """Derive {disposition, confirmed_strength} per DESIGN §13.1 Phase 4.

    On invalid input (bad score type, missing actionability for confirmed
    band, unknown actionability), emits error-as-prompt and sys.exits with
    EXIT_VALIDATION — caller's batch loop halts there.
    """
    fid = tup.get("id") or f"tuple #{idx}"
    score = tup.get("score_phase4")

    if score is None:
        return {"disposition": "uncertain", "confirmed_strength": None}

    if not isinstance(score, (int, float)) or isinstance(score, bool):
        c.err_prompt(
            f"--apply-decisions tuple #{idx} ({fid}): score_phase4 must be number or null, got {type(score).__name__}",
            action="pass score_phase4 as an integer 0-100 or null (for parse-failure fallback)."
        )
        sys.exit(c.EXIT_VALIDATION)

    if score < 45:
        return {"disposition": "disproven", "confirmed_strength": None}
    if score < 60:
        return {"disposition": "uncertain", "confirmed_strength": None}

    # Confirmed band — needs actionability.
    actionability = tup.get("actionability")
    if actionability is None:
        c.err_prompt(
            f"--apply-decisions tuple #{idx} ({fid}): score_phase4={score} is in the confirmed band (>=60) but no actionability provided",
            valid_values=sorted(_ACTIONABILITY_TO_DISPOSITION.keys()),
            action="add actionability to the tuple (auto_fixable/manual/report_only); the validator owns that classification."
        )
        sys.exit(c.EXIT_VALIDATION)
    if actionability not in _ACTIONABILITY_TO_DISPOSITION:
        c.err_prompt(
            f"--apply-decisions tuple #{idx} ({fid}): unknown actionability '{actionability}'",
            valid_values=sorted(_ACTIONABILITY_TO_DISPOSITION.keys()),
            did_you_mean=c.suggest(actionability, _ACTIONABILITY_TO_DISPOSITION.keys()),
            action="see DESIGN §5.2 / schema-v1.json for the actionability enum."
        )
        sys.exit(c.EXIT_VALIDATION)

    return {
        "disposition": _ACTIONABILITY_TO_DISPOSITION[actionability],
        "confirmed_strength": "strong" if score >= 75 else "moderate",
    }


def cmd_apply_decisions(args):
    """Apply a batch of Phase-4 decision tuples (§13.1, §21.2; Stage 2.5.B)."""
    decisions = read_json_arg(args.apply_decisions, "--apply-decisions")

    if not isinstance(decisions, list):
        c.err_prompt(
            f"--apply-decisions expects a JSON array, got {type(decisions).__name__}",
            action="pass an array of decision tuples; see artifact-patch.py docstring for the shape."
        )
        return c.EXIT_USAGE

    # --expected guard (Phase 4 structural invariant). Caller passes the
    # count of candidates it dispatched in this wave (deep + light), and
    # the helper rejects when fewer tuples arrive. Two failure modes the
    # guard catches:
    #   - deep lane: orchestrator collapsed multiple candidates into a
    #     single batched Opus call (re-dispatch one Agent per candidate);
    #   - light lane: a chunk-agent dropped findings from its returned
    #     array (re-dispatch the chunk for the missing ids).
    # Either way, surface loudly so per-finding blast-radius work / per-
    # candidate confirmation isn't silently lost. Pass --expected 0 (or
    # omit) only when the caller doesn't know N.
    if args.expected > 0 and len(decisions) != args.expected:
        received_ids = [
            (t.get("id") if isinstance(t, dict) and t.get("id") else f"<#{i}>")
            for i, t in enumerate(decisions)
        ]
        c.err_prompt(
            f"--apply-decisions expected {args.expected} tuple(s) but received {len(decisions)}",
            context=(
                f"received tuple ids: {received_ids}" if received_ids
                else "received empty tuple array"
            ),
            action=(
                "every dispatched candidate must produce its own decision tuple. "
                "Two failure modes share this guard: (1) deep lane — the "
                "orchestrator collapsed multiple deep-lane candidates into one "
                "Opus call (re-dispatch one Agent per candidate and recompose "
                "the tuple array on the full per-finding result set); (2) light "
                "lane — a chunk-agent dropped findings from its returned array, "
                "or returned extra hallucinated ids (re-dispatch the chunk for "
                "the missing ids, or strip the hallucinated ids before the "
                "re-invoke). Do NOT lower --expected to match the received "
                "count — the guard is exactly what is supposed to catch this. "
                "See fragments/05-validation.md §4.4."
            )
        )
        return c.EXIT_EXPECTED_MISMATCH

    # Duplicate-id guard runs unconditionally (independent of --expected).
    # A chunk-agent that returns the same finding-id twice (or one extra
    # hallucinated id matching an existing finding's id) would pass the
    # count check and then trigger _apply_finding_set twice on the same
    # finding, producing two score_history phase_4 entries for one Phase
    # 4 score. Reject the batch up front so the orchestrator strips the
    # duplicate before re-invoking.
    seen_ids = {}
    duplicates = []
    for i, t in enumerate(decisions):
        if not isinstance(t, dict):
            continue  # the per-tuple loop below handles non-object rejection
        tid = t.get("id")
        if not tid:
            continue  # the per-tuple loop below requires non-empty id
        if tid in seen_ids:
            duplicates.append(tid)
        else:
            seen_ids[tid] = i
    if duplicates:
        # Dedup the duplicates list itself so the message stays short on a
        # batch where one id appears 3+ times.
        dup_unique = sorted(set(duplicates))
        c.err_prompt(
            f"--apply-decisions has duplicate finding id(s): {dup_unique}",
            context="every tuple in a single --apply-decisions batch must name a distinct finding id; duplicates would re-apply the decision (and re-append score_history) to the same finding.",
            action="strip the duplicate tuples (or merge them) and re-invoke. A duplicate is usually a chunk-agent returning the same id twice, or a hallucinated id that collides with an existing finding."
        )
        return c.EXIT_VALIDATION

    counts = {"confirmed_mechanical": 0, "confirmed_manual": 0, "confirmed_report": 0,
              "uncertain": 0, "disproven": 0}

    for idx, tup in enumerate(decisions):
        if not isinstance(tup, dict):
            c.err_prompt(
                f"--apply-decisions tuple #{idx}: must be a JSON object, got {type(tup).__name__}",
                action="each array element is {id, score_phase4, ...}; see the docstring."
            )
            return c.EXIT_VALIDATION

        fid = tup.get("id")
        if not fid:
            c.err_prompt(
                f"--apply-decisions tuple #{idx}: 'id' is required",
                action="every tuple must name the finding it applies to."
            )
            return c.EXIT_VALIDATION

        bad_keys = [k for k in tup.keys() if k not in ALLOWED_DECISION_TUPLE_KEYS]
        if bad_keys:
            c.err_prompt(
                f"--apply-decisions tuple #{idx} ({fid}): unknown keys {sorted(bad_keys)}",
                valid_values=sorted(ALLOWED_DECISION_TUPLE_KEYS),
                action="remove unknown keys; disposition/is_actionable are derived by the helper, not supplied."
            )
            return c.EXIT_VALIDATION

        derived = _derive_phase4_disposition(tup, idx)

        # Load fresh per-tuple so preceding tuples' writes are visible on the
        # next iteration's base state. Matches the "per-tuple atomic writes"
        # semantics documented in the plan (Stage 2.5.B §5.2).
        artifact = _load_or_fail(args.path)
        finding = _find_finding(artifact, fid)

        # Build --set pairs. _apply_finding_set handles the is_actionable
        # derivation and the current_state↔disposition coupling checks for us.
        set_pairs = [("disposition", derived["disposition"])]
        if "score_phase4" in tup:
            set_pairs.append(("score_phase4", tup["score_phase4"]))
        # actionability: write only when non-null — schema requires a concrete
        # enum value. A tuple passing `actionability: null` (valid for
        # disproven/uncertain where it's not needed) leaves the finding's
        # Phase-1-assigned actionability in place.
        if tup.get("actionability") is not None:
            set_pairs.append(("actionability", tup["actionability"]))

        # confirmed_strength: tuple override beats derived. `null` from the
        # tuple counts as an explicit override (e.g., downgrading from a
        # prior-phase classification); use a sentinel check.
        if "confirmed_strength" in tup:
            set_pairs.append(("confirmed_strength", tup["confirmed_strength"]))
        else:
            set_pairs.append(("confirmed_strength", derived["confirmed_strength"]))

        # reason: if the tuple provides one use it, else fill a disposition-
        # appropriate default. Matches the prose in 05-validation step 4.4.
        if "reason" in tup:
            set_pairs.append(("reason", tup["reason"]))
        else:
            default_reason = {
                "disproven": "disproven by Phase 4",
                "uncertain": "uncertain (Phase 4 inconclusive)",
            }.get(derived["disposition"])  # None for confirmed band, which is correct
            set_pairs.append(("reason", default_reason))

        if "related_parent_finding_id" in tup:
            set_pairs.append(("related_parent_finding_id", tup["related_parent_finding_id"]))

        _apply_finding_set(finding, set_pairs)

        # validation_result: write only when the resolved disposition lands in
        # the confirmed band. Schema requires nested non-null for the stored
        # object, and disproven/uncertain validators don't produce the
        # fix_proposal / verification_context sections.
        vr = tup.get("validation_result")
        if vr is not None and derived["disposition"] in CONFIRMED_BAND:
            _apply_finding_set_json(finding, [("validation_result", vr)])

        rc = _write_and_emit(args.path, artifact, silent=True)
        if rc != c.EXIT_OK:
            # _write_and_emit already emitted an error-as-prompt for invalid
            # post-patch state. Halt the batch; preceding tuples persisted.
            return rc

        counts[derived["disposition"]] += 1

    total = sum(counts.values())
    print(
        f"applied {total} decisions "
        f"(confirmed_mechanical={counts['confirmed_mechanical']}, "
        f"confirmed_manual={counts['confirmed_manual']}, "
        f"confirmed_report={counts['confirmed_report']}, "
        f"uncertain={counts['uncertain']}, "
        f"disproven={counts['disproven']})"
    )
    return c.EXIT_OK


# ----- --apply-fix-start / --apply-fix-outcomes (Stage 3, DESIGN §4 Phase 8/9) ---
#
# These two modes collapse per-finding loops at the start and end of a fix
# run into single batched helper calls, matching the authoring discipline
# captured at Stage 2.5.C (and first applied at Stage 2.5.B via
# --apply-decisions). Same pattern: JSON array input, per-tuple atomic
# write, first-failure halts.
#
# --apply-fix-start applies at Phase 8 step 8.4 (all eligible findings go
# open → attempted before fix-group agents dispatch). --apply-fix-outcomes
# applies at Phase 9d (every touched finding transitions per phase_9_outcome
# and gets its fix_attempt appended).
#
# Derivation table (§4 Phase 9d / §13.1 Phase 9):
#   phase_9_outcome == "verified"   → attempted → resolved, disposition=resolved
#   phase_9_outcome == "partial"    → attempted → open,     disposition=partial,
#                                      reason=f"fix partial: {phase_9_finding}"
#   phase_9_outcome == "regression" → attempted → open,     disposition=regression,
#                                      reason=f"fix regressed: {phase_9_finding}"
#                                      (output_sha MUST be null — the group reverted)
#   phase_9_outcome == null (overlap-abort) → no transition (stays attempted),
#                                      fix_attempt still appended for audit trail.

ALLOWED_FIX_START_TUPLE_KEYS = frozenset({"id", "run_id"})

ALLOWED_FIX_OUTCOME_TUPLE_KEYS = frozenset({
    "id",
    "run_id",
    "fix_group_id",
    "input_sha",
    "output_sha",
    "phase_9_outcome",
    "phase_9_finding",
    "revised_fix_proposal",
    "timestamp",
})

_REQUIRED_FIX_OUTCOME_KEYS = frozenset({
    "id", "run_id", "fix_group_id", "input_sha",
    "output_sha", "phase_9_outcome", "timestamp",
})

_PHASE_9_OUTCOME_VALUES = frozenset({"verified", "partial", "regression", None})


def _check_fix_tuple(tup, idx, flag, allowed_keys):
    """Shared tuple-shape validator for --apply-fix-start and --apply-fix-outcomes.

    Rejects non-object tuples, missing id, and unknown keys. Returns the
    finding id so the caller can pick up.
    """
    if not isinstance(tup, dict):
        c.err_prompt(
            f"{flag} tuple #{idx}: must be a JSON object, got {type(tup).__name__}",
            action="each array element is an object; see artifact-patch.py docstring for the shape."
        )
        sys.exit(c.EXIT_VALIDATION)

    fid = tup.get("id")
    if not fid:
        c.err_prompt(
            f"{flag} tuple #{idx}: 'id' is required",
            action="every tuple must name the finding it applies to."
        )
        sys.exit(c.EXIT_VALIDATION)

    bad_keys = [k for k in tup.keys() if k not in allowed_keys]
    if bad_keys:
        c.err_prompt(
            f"{flag} tuple #{idx} ({fid}): unknown keys {sorted(bad_keys)}",
            valid_values=sorted(allowed_keys),
            action="remove unknown keys; the helper derives state from the documented inputs."
        )
        sys.exit(c.EXIT_VALIDATION)

    return fid


def cmd_apply_fix_start(args):
    """Bulk open→attempted at the start of Phase 8 (DESIGN §4 Phase 8, Stage 3)."""
    tuples = read_json_arg(args.apply_fix_start, "--apply-fix-start")

    if not isinstance(tuples, list):
        c.err_prompt(
            f"--apply-fix-start expects a JSON array, got {type(tuples).__name__}",
            action="pass an array of {id, run_id} objects; see artifact-patch.py docstring."
        )
        return c.EXIT_USAGE

    transitioned = 0
    for idx, tup in enumerate(tuples):
        fid = _check_fix_tuple(tup, idx, "--apply-fix-start", ALLOWED_FIX_START_TUPLE_KEYS)

        # run_id is required for audit consistency even though we don't
        # persist it on findings here — the caller passes the same run_id
        # it'll use at Phase 9d, so trace.md / error messages can correlate.
        if not tup.get("run_id"):
            c.err_prompt(
                f"--apply-fix-start tuple #{idx} ({fid}): 'run_id' is required",
                action="pass the run_id captured at Phase 7 step 7.8 (fixrun_<ULID>)."
            )
            return c.EXIT_VALIDATION

        # Load fresh per-tuple so preceding tuples' writes are visible
        # (same pattern as --apply-decisions). Eligibility is the
        # orchestrator's job at Phase 8 step 8.1; here we only enforce the
        # §5.3 transition and the schema.
        artifact = _load_or_fail(args.path)
        finding = _find_finding(artifact, fid)

        # Phase 8 eligibility (§4 Phase 8): the finding must be open at
        # entry. _apply_finding_set short-circuits on same→same (e.g.,
        # attempted→attempted is a silent no-op), which would hide a real
        # orchestrator bug — Phase 7 step 4's leftover-attempted hard
        # abort is supposed to catch every stale attempted state before
        # Phase 8 dispatches. Reject loudly if we see attempted/resolved
        # so the orchestrator's Phase 7 gate stays the only legitimate
        # recovery path.
        before_state = finding.get("current_state")
        if before_state != "open":
            allowed = c.transitions_from(before_state)
            c.err_prompt(
                f"--apply-fix-start tuple #{idx} ({fid}): current_state='{before_state}' is not 'open'",
                context=(
                    "Phase 8 eligibility (§4 Phase 8) requires current_state=='open'. "
                    "A leftover 'attempted' finding should have triggered the Phase 7 step 4 hard abort; "
                    "a 'resolved' finding should have been filtered out of eligibility."
                ),
                valid_values=(sorted(allowed) or ["(none — terminal state)"]),
                action="run /adamsreview:fix fresh; if this persists, check the Phase 8 step 8.1 eligibility filter."
            )
            sys.exit(c.EXIT_INVALID_TRANSITION)

        # open → attempted is valid; _apply_finding_set enforces the §5.3
        # transition whitelist via transitions_from() anyway, as a defense
        # in depth against future edits to this guard.
        _apply_finding_set(finding, [("current_state", "attempted")])

        rc = _write_and_emit(args.path, artifact, silent=True)
        if rc != c.EXIT_OK:
            return rc
        transitioned += 1

    print(f"apply-fix-start: transitioned {transitioned} finding(s) open→attempted")
    return c.EXIT_OK


def _build_fix_attempt(tup):
    """Assemble the fix_attempts[] entry from a Phase-9 outcome tuple.

    Required schema fields (run_id, timestamp, fix_group_id, input_sha,
    output_sha, phase_9_outcome) are copied verbatim — schema validation
    at write time catches pattern/enum violations with a clear error.
    phase_9_finding and revised_fix_proposal are optional; include only
    when the tuple provides them so absent keys don't render as `null`
    in a place the schema treats as nullable-vs-absent differently.
    """
    attempt = {
        "run_id": tup["run_id"],
        "timestamp": tup["timestamp"],
        "fix_group_id": tup["fix_group_id"],
        "input_sha": tup["input_sha"],
        "output_sha": tup.get("output_sha"),
        "phase_9_outcome": tup.get("phase_9_outcome"),
    }
    if "phase_9_finding" in tup:
        attempt["phase_9_finding"] = tup["phase_9_finding"]
    if "revised_fix_proposal" in tup:
        attempt["revised_fix_proposal"] = tup["revised_fix_proposal"]
    return attempt


def cmd_apply_fix_outcomes(args):
    """Phase 9d: append fix_attempts + transition state per phase_9_outcome."""
    tuples = read_json_arg(args.apply_fix_outcomes, "--apply-fix-outcomes")

    if not isinstance(tuples, list):
        c.err_prompt(
            f"--apply-fix-outcomes expects a JSON array, got {type(tuples).__name__}",
            action="pass an array of outcome tuples; see artifact-patch.py docstring."
        )
        return c.EXIT_USAGE

    # Duplicate-id guard runs unconditionally. Two tuples for the same
    # finding in one batch would cause two fix_attempt appends and two
    # state transitions for one Phase-9 outcome — audit-trail pollution
    # at best, schema invariant violation at worst (e.g. partial+verified
    # for the same finding in one call).
    seen_ids = {}
    duplicates = []
    for i, t in enumerate(tuples):
        if not isinstance(t, dict):
            continue  # the per-tuple loop handles non-object rejection
        tid = t.get("id")
        if not tid:
            continue  # the per-tuple loop requires non-empty id
        if tid in seen_ids:
            duplicates.append(tid)
        else:
            seen_ids[tid] = i
    if duplicates:
        dup_unique = sorted(set(duplicates))
        c.err_prompt(
            f"--apply-fix-outcomes has duplicate finding id(s): {dup_unique}",
            context="every tuple in a single --apply-fix-outcomes batch must name a distinct finding id; duplicates would re-append fix_attempts and re-transition state for the same finding in one call.",
            action="strip the duplicate tuples (or merge them) and re-invoke."
        )
        return c.EXIT_VALIDATION

    counts = {"verified": 0, "partial": 0, "regression": 0, "overlap_abort": 0}

    for idx, tup in enumerate(tuples):
        fid = _check_fix_tuple(tup, idx, "--apply-fix-outcomes", ALLOWED_FIX_OUTCOME_TUPLE_KEYS)

        missing = [k for k in _REQUIRED_FIX_OUTCOME_KEYS if k not in tup]
        if missing:
            c.err_prompt(
                f"--apply-fix-outcomes tuple #{idx} ({fid}): missing required key(s) {sorted(missing)}",
                valid_values=sorted(_REQUIRED_FIX_OUTCOME_KEYS),
                action="every tuple needs id, run_id, fix_group_id, input_sha, output_sha, phase_9_outcome, timestamp. output_sha / phase_9_outcome may be null."
            )
            return c.EXIT_VALIDATION

        outcome = tup["phase_9_outcome"]
        if outcome not in _PHASE_9_OUTCOME_VALUES:
            c.err_prompt(
                f"--apply-fix-outcomes tuple #{idx} ({fid}): unknown phase_9_outcome '{outcome}'",
                valid_values=["verified", "partial", "regression", "null (overlap-abort)"],
                did_you_mean=c.suggest(outcome, ["verified", "partial", "regression"]),
                action="see DESIGN §13.1 Phase 9 / §4 Phase 9.pre for the valid outcomes."
            )
            return c.EXIT_VALIDATION

        # Regression findings must have output_sha=null — their fix group
        # was reverted in §4 Phase 9b so no commit exists for this finding.
        # Enforce so an orchestrator bug can't ship a regression-with-SHA.
        if outcome == "regression" and tup.get("output_sha") is not None:
            c.err_prompt(
                f"--apply-fix-outcomes tuple #{idx} ({fid}): regression outcome requires output_sha=null",
                context="DESIGN §13.1 Phase 9 / §6 schema note: regression findings have their fix group reverted in §4 Phase 9b, so no commit exists for them.",
                action="pass output_sha: null for any tuple with phase_9_outcome=regression."
            )
            return c.EXIT_VALIDATION

        # Overlap-abort (phase_9_outcome=null, §4 Phase 9.pre step 5): must
        # also carry output_sha=null AND a phase_9_finding describing the
        # abort. The schema allows phase_9_finding as an optional string —
        # require it here so the audit trail is legible.
        if outcome is None:
            if tup.get("output_sha") is not None:
                c.err_prompt(
                    f"--apply-fix-outcomes tuple #{idx} ({fid}): overlap-abort outcome (null) requires output_sha=null",
                    context="Phase 9.pre aborts before any commit — no SHA to record.",
                    action="pass output_sha: null alongside phase_9_outcome: null."
                )
                return c.EXIT_VALIDATION
            if not tup.get("phase_9_finding"):
                c.err_prompt(
                    f"--apply-fix-outcomes tuple #{idx} ({fid}): overlap-abort outcome (null) requires phase_9_finding diagnostic text",
                    action="populate phase_9_finding with the overlap description (e.g. 'run aborted: fix agents touched overlapping files — <files>')."
                )
                return c.EXIT_VALIDATION

        artifact = _load_or_fail(args.path)
        finding = _find_finding(artifact, fid)

        # 1) Append the fix_attempt. Schema validation at write time
        # catches malformed SHAs, bad run_id pattern, bad fix_group_id, etc.
        finding.setdefault("fix_attempts", []).append(_build_fix_attempt(tup))

        # 2) State transition + disposition / reason, per outcome.
        if outcome == "verified":
            _apply_finding_set(finding, [
                ("current_state", "resolved"),
                ("disposition", "resolved"),
                ("reason", None),
            ])
            counts["verified"] += 1
        elif outcome == "partial":
            pf = tup.get("phase_9_finding")
            reason = f"fix partial: {pf}" if pf else "fix partial"
            _apply_finding_set(finding, [
                ("current_state", "open"),
                ("disposition", "partial"),
                ("reason", reason),
            ])
            counts["partial"] += 1
        elif outcome == "regression":
            pf = tup.get("phase_9_finding")
            reason = f"fix regressed: {pf}" if pf else "fix regressed"
            _apply_finding_set(finding, [
                ("current_state", "open"),
                ("disposition", "regression"),
                ("reason", reason),
            ])
            counts["regression"] += 1
        else:
            # outcome is None — overlap-abort. Leave current_state at
            # attempted (the leftover-attempted hard abort in §4 Phase 7
            # step 4 is the deterministic recovery path). No state
            # transition; the fix_attempt we just appended is the full
            # audit record.
            counts["overlap_abort"] += 1

        rc = _write_and_emit(args.path, artifact, silent=True)
        if rc != c.EXIT_OK:
            return rc

    total = sum(counts.values())
    print(
        f"apply-fix-outcomes: applied {total} outcome(s) "
        f"(verified={counts['verified']}, partial={counts['partial']}, "
        f"regression={counts['regression']}, overlap_abort={counts['overlap_abort']})"
    )
    return c.EXIT_OK


def cmd_set_and_or_append(args):
    """Combined --set / --set-json / --append-fix-attempt (DESIGN §26).

    Any combination can be present. All operate on --finding-id when
    given (or top-level, for --set and --set-json). Order within one
    call: --set first (scalar transitions + coupling), then --set-json
    (structured fields), then --append-fix-attempt. One atomic write.
    """
    artifact = _load_or_fail(args.path)
    before = copy.deepcopy(artifact) if args.dry_run else None

    set_pairs = [parse_set_pair(p) for p in args.set] if args.set else []
    set_json_pairs = [parse_set_json_pair(p) for p in args.set_json] if args.set_json else []

    if args.append_fix_attempt is not None and not args.finding_id:
        c.err_prompt(
            "--append-fix-attempt requires --finding-id",
            action="fix_attempts is a per-finding list; pass --finding-id <id>."
        )
        return c.EXIT_USAGE

    if args.finding_id:
        finding = _find_finding(artifact, args.finding_id)
        if set_pairs:
            _apply_finding_set(finding, set_pairs)
        if set_json_pairs:
            _apply_finding_set_json(finding, set_json_pairs)
        if args.append_fix_attempt is not None:
            attempt = read_json_arg(args.append_fix_attempt, "--append-fix-attempt")
            if not isinstance(attempt, dict):
                c.err_prompt(
                    f"--append-fix-attempt expects a JSON object, got {type(attempt).__name__}",
                    action="pass a fix_attempt object matching DESIGN §6."
                )
                return c.EXIT_USAGE
            finding.setdefault("fix_attempts", []).append(attempt)
    else:
        # Top-level: --set and/or --set-json only.
        if set_pairs:
            _apply_artifact_set(artifact, set_pairs)
        if set_json_pairs:
            _apply_artifact_set_json(artifact, set_json_pairs)

    return _write_and_emit(args.path, artifact, dry_run=args.dry_run, before=before)


# ----- CLI ---------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        prog="artifact-patch.py",
        description="Canonical writer for artifact.json (DESIGN §8.2, §21.2)."
    )
    p.add_argument(
        "--path",
        required=True,
        help="target artifact.json path (absolute recommended)"
    )
    p.add_argument(
        "--finding-id",
        metavar="FXXX",
        help="target finding for --set / --append-fix-attempt; omit for top-level --set"
    )
    p.add_argument(
        "--set",
        dest="set",
        action="append",
        default=[],
        metavar="FIELD=VALUE",
        help="repeatable: set a scalar field to a JSON-parseable value (null/true/85/foo)"
    )
    p.add_argument(
        "--set-json",
        dest="set_json",
        action="append",
        default=[],
        metavar="FIELD=<json-or-@file>",
        help="repeatable: set an array/object field (whitelisted). Value is inline JSON, @<file>, or - for stdin."
    )
    p.add_argument(
        "--append-fix-attempt",
        dest="append_fix_attempt",
        metavar="ATTEMPT_JSON",
        help="append an entry to finding.fix_attempts[] (requires --finding-id; inline JSON, @file, or -)"
    )
    p.add_argument(
        "--dry-run",
        dest="dry_run",
        action="store_true",
        help="validate the patch in memory and print a unified diff to stdout; no write"
    )
    p.add_argument(
        "--expected",
        type=int,
        default=0,
        metavar="N",
        help="(--apply-decisions only) expected tuple count; rejects count mismatch (over- or under-sized batches) with EXIT_EXPECTED_MISMATCH (exit 6). Pass N=0 (default) or omit to skip the check (when caller doesn't know N)."
    )
    mode = p.add_mutually_exclusive_group(required=False)
    mode.add_argument(
        "--init",
        metavar="SEED_JSON",
        help="create fresh artifact from seed (inline JSON, @file, or -)"
    )
    mode.add_argument(
        "--add-finding",
        metavar="FINDING_JSON",
        help="append a new finding to findings[] (inline JSON, @file, or -)"
    )
    mode.add_argument(
        "--add-findings",
        dest="add_findings",
        metavar="FINDINGS_JSON",
        help="batched: append a JSON array of findings in one atomic write "
             "(inline JSON, @file, or - for stdin). Continues on per-finding "
             "validation failures; emits structured stderr per rejection."
    )
    mode.add_argument(
        "--delete-finding",
        metavar="FXXX",
        help="remove a finding by id (used by Phase 2 dedup)"
    )
    mode.add_argument(
        "--apply-decisions",
        dest="apply_decisions",
        metavar="DECISIONS_JSON",
        help="apply a batch of Phase-4 decision tuples (inline JSON array, @file, or -); see docstring"
    )
    mode.add_argument(
        "--apply-fix-start",
        dest="apply_fix_start",
        metavar="FIX_START_JSON",
        help="Stage 3 (Phase 8): bulk open→attempted transition. Array of {id, run_id}. Inline/@file/-."
    )
    mode.add_argument(
        "--apply-fix-outcomes",
        dest="apply_fix_outcomes",
        metavar="FIX_OUTCOMES_JSON",
        help="Stage 3 (Phase 9d): fix_attempt append + state transition per phase_9_outcome. Inline/@file/-."
    )
    return p


def main():
    parser = build_parser()
    args = parser.parse_args()

    # --expected is meaningful only in --apply-decisions mode. Reject early
    # if it's set without --apply-decisions so a typo doesn't silently
    # become a no-op.
    if args.expected and args.apply_decisions is None:
        parser.error("--expected is only valid with --apply-decisions")
    if args.expected < 0:
        parser.error("--expected must be >= 0")

    try:
        if args.init is not None:
            if args.set or args.set_json or args.append_fix_attempt:
                parser.error("--init cannot combine with --set / --set-json / --append-fix-attempt")
            return cmd_init(args)
        if args.add_finding is not None:
            if args.set or args.set_json or args.append_fix_attempt:
                parser.error("--add-finding cannot combine with --set / --set-json / --append-fix-attempt")
            return cmd_add_finding(args)
        if args.add_findings is not None:
            # Mode-conflict + --dry-run paths exit with EXIT_USAGE (64)
            # directly via sys.exit instead of parser.error(), which would
            # emit argparse's default exit code (2). The new --add-findings
            # mode's docstring contract pins these paths to 64; the older
            # modes' parser.error() calls stay as-is (they already exit 2
            # today and aren't in scope for this stage).
            if args.set or args.set_json or args.append_fix_attempt or args.finding_id:
                c.err_prompt(
                    "--add-findings cannot combine with --set / --set-json / --append-fix-attempt / --finding-id (each finding carries its own id)",
                    action="remove the conflicting flag(s); --add-findings is a batched create."
                )
                return c.EXIT_USAGE
            if args.dry_run:
                # Note: unlike --apply-decisions/--apply-fix-*, --add-findings
                # does a single atomic write, so --dry-run could be made
                # meaningful here (rehearse preflight + post-write validation
                # without committing). Leaving it rejected for the minimum
                # version to keep parity; promote to supported when the first
                # caller asks for it.
                c.err_prompt(
                    "--add-findings does not currently support --dry-run",
                    action="use a throwaway --path to preflight (e.g., a tempfile)."
                )
                return c.EXIT_USAGE
            return cmd_add_findings(args)
        if args.delete_finding is not None:
            if args.set or args.set_json or args.append_fix_attempt:
                parser.error("--delete-finding cannot combine with --set / --set-json / --append-fix-attempt")
            return cmd_delete_finding(args)
        if args.apply_decisions is not None:
            if args.set or args.set_json or args.append_fix_attempt or args.finding_id:
                parser.error("--apply-decisions cannot combine with --set / --set-json / --append-fix-attempt / --finding-id (tuples carry their own finding ids)")
            if args.dry_run:
                parser.error("--apply-decisions does not currently support --dry-run (batches write per tuple; run on a throwaway path or validate tuples upstream)")
            return cmd_apply_decisions(args)
        if args.apply_fix_start is not None:
            if args.set or args.set_json or args.append_fix_attempt or args.finding_id:
                parser.error("--apply-fix-start cannot combine with --set / --set-json / --append-fix-attempt / --finding-id (tuples carry their own finding ids)")
            if args.dry_run:
                parser.error("--apply-fix-start does not support --dry-run (batched per-tuple writes; validate tuples upstream or use a throwaway path)")
            return cmd_apply_fix_start(args)
        if args.apply_fix_outcomes is not None:
            if args.set or args.set_json or args.append_fix_attempt or args.finding_id:
                parser.error("--apply-fix-outcomes cannot combine with --set / --set-json / --append-fix-attempt / --finding-id (tuples carry their own finding ids)")
            if args.dry_run:
                parser.error("--apply-fix-outcomes does not support --dry-run (batched per-tuple writes; validate tuples upstream or use a throwaway path)")
            return cmd_apply_fix_outcomes(args)
        if args.set or args.set_json or args.append_fix_attempt is not None:
            return cmd_set_and_or_append(args)
    except SystemExit:
        raise
    except Exception as e:
        c.err_prompt(
            f"unexpected error: {type(e).__name__}: {e}",
            action="this is a bug; full traceback follows below."
        )
        traceback.print_exc(file=sys.stderr)
        return c.EXIT_UNEXPECTED

    parser.error("no mode selected (use --init, --add-finding, --add-findings, --delete-finding, --apply-decisions, --apply-fix-start, --apply-fix-outcomes, --set, --set-json, or --append-fix-attempt)")


if __name__ == "__main__":
    sys.exit(main())
