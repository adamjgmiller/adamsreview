#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["json-repair", "jsonschema"]
# ///
"""parse-validator-result.py — canonicalize Phase 4 validator output.

Contract:
    parse-validator-result.py --lane deep|light < raw.json > canonical.json
      exit 0: canonical JSON on stdout
      exit 1: empty/bad invocation (missing --lane, empty stdin)
      exit 2: cannot coerce any score to 0-100

Canonical output shape (always emitted on exit 0):

    {
      "score_phase4": <int 0-100>,
      "actionability": "auto_fixable" | "manual" | "report_only" | null,
      "confirmed_strength": "strong" | "moderate" | "weak",
      "decision": "confirmed" | "disproven" | "uncertain" | null,
      "notes": "<free-form — records scale inference or source shape>",
      "validation_result": { ... } | null,   (deep-lane passthrough)
      "related_candidates_to_investigate": [ ... ]   (deep-lane passthrough)
    }

The `confirmed_strength` convention matches CLAUDE.md §Phase 4 — the
§13.1 Phase-4 table:
  - `score_phase4 >= 75`             → "strong"
  - `60 <= score_phase4 < 75`        → "moderate"
  - `score_phase4 < 60`              → "weak"  (below the confirmed band;
    artifact-patch.py's --apply-decisions normalizes this to null when
    writing, so this field is advisory for pipe consumers only)

Input shapes handled (normalized to `score_phase4` int on 0-100):

  A) Canonical: `{score_phase4: <int>}`  — pass through.
  B) Nested:    `{score: {correctness: <int>}}` — extract the first
                inner numeric value.
  C) 1-5 scale: `{overall_numeric: <float 1.0-5.0>}` — multiply by 20.
  D) Severity:  `{severity: "low" | "medium" | "high"}` → 35 | 60 | 85.
  E) Ambiguous: `{score: <N>}` with no scale hint. Heuristic:
       - N <= 10 AND N > 5 → treat as 1-10 (multiply by 10).
       - N <= 5 AND N >= 1 → treat as 1-5 (multiply by 20).
       - N > 10 AND N <= 100 → pass through.
       - else → reject (exit 2).
     Whenever the heuristic or a scale-map fires, `scale_inferred: true`
     is appended to `notes` so the audit trail records the guess.

On parse failure (json-repair can't salvage the raw input) this helper
also exits 2 — the caller should route the finding to `uncertain` per
§13.1 Phase-4 table row 1 (`score_phase4: null`).

`actionability` (must be one of auto_fixable | manual | report_only):
  - Pass through if the raw output carries it at top level.
  - Else: emit `null` and note "actionability absent".
  - `artifact-patch.py --apply-decisions` requires actionability when
    `score_phase4 >= 60` — callers gate the tuple accordingly.

Deep-lane passthrough:
  - `validation_result` (the nested object with evidence/blast_radius/
    fix_proposal/verification_context) is carried through verbatim when
    present; `null` otherwise.
  - After any top-level lift (see below), the deep-lane `validation_result`
    is schema-checked against `bin/schema-v1.json#/$defs/validation_result`.
    On mismatch — drifted keys, missing required sub-objects, malformed
    shape — `vr` is dropped to `None` and a concise
    "validation_result shape unrecoverable: <first two error paths>"
    note is appended. This preserves the finding (routing it to
    `uncertain` in combination with a 45-59 score, or to
    `confirmed_*` with vr=null at >= 60) rather than letting the
    downstream `artifact-patch.py --apply-decisions` reject the whole
    tuple and halt the batch.
  - Top-level lift: if `validation_result` is absent but the raw carries
    `evidence` / `blast_radius` / `fix_proposal` / `verification_context`
    at the top level (a known validator shape drift), those are lifted
    into `vr` BEFORE the schema check — so a legitimately-recoverable
    drift still passes through.
  - `related_candidates_to_investigate` passthrough for Wave 2 seeding.

Light-lane outputs typically don't carry either of those — the canonical
emits `null` / `[]`. Schema check fires only on the deep lane.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import (  # noqa: E402
    err_prompt,
    validation_result_validator,
    EXIT_OK,
    EXIT_VALIDATION,
    EXIT_SCORE_UNRECOVERABLE,
)


# ----- score coercion ----------------------------------------------------

SEVERITY_MAP = {"low": 35, "medium": 60, "high": 85}
STRENGTH_BANDS = (
    (75, "strong"),
    (60, "moderate"),
    (0,  "weak"),
)


def _strength(score: int) -> str:
    for threshold, label in STRENGTH_BANDS:
        if score >= threshold:
            return label
    return "weak"


def _coerce_score(raw: dict) -> tuple[int, list[str]]:
    """Return (score_phase4 in 0..100, notes_fragments).

    Raises ValueError when no numeric score can be recovered.
    notes_fragments is a list of short strings appended to the canonical
    `notes` field so downstream audit trail reflects the coercion.
    """
    notes: list[str] = []

    # A) Canonical.
    if isinstance(raw.get("score_phase4"), (int, float)):
        score = float(raw["score_phase4"])
        # Still range-check — a validator emitting 6.0 "score_phase4" is
        # mislabeled. Route through the ambiguous heuristic if it's
        # clearly not 0-100.
        if 0 <= score <= 100:
            return int(round(score)), notes
        # Weird case — e.g. "score_phase4": 6 from a confused validator.
        # Fall through to heuristic with `score` as the raw candidate.
        ambiguous = score
    else:
        ambiguous = None

    # B) Nested score object.
    if isinstance(raw.get("score"), dict):
        inner = raw["score"]
        for key, val in inner.items():
            if isinstance(val, (int, float)):
                notes.append(f"extracted nested score.{key}")
                # Recurse through heuristic with this numeric.
                s = _heuristic_scale(val, notes)
                return s, notes
        raise ValueError(f"score: {inner!r} nested object has no numeric value")

    # C) 1-5 scale.
    if isinstance(raw.get("overall_numeric"), (int, float)):
        v = float(raw["overall_numeric"])
        if 1.0 <= v <= 5.0:
            notes.append("scale_inferred: 1-5 via overall_numeric (*20)")
            return int(round(v * 20)), notes
        # Out of 1-5 band — fall through to heuristic below, but only if
        # Section A didn't already stash an out-of-range score_phase4
        # hint. Section A takes precedence (mirrors Section E's guard);
        # otherwise an out-of-band overall_numeric would silently
        # overwrite an out-of-band score_phase4 and apply the heuristic
        # to the wrong number.
        if ambiguous is None:
            ambiguous = v
        else:
            notes.append(
                f"overall_numeric {v} out of 1-5 band and score_phase4 hint already present; discarding overall_numeric"
            )

    # D) Severity string.
    if isinstance(raw.get("severity"), str):
        sev = raw["severity"].strip().lower()
        if sev in SEVERITY_MAP:
            notes.append(f"scale_inferred: severity={sev} -> {SEVERITY_MAP[sev]}")
            return SEVERITY_MAP[sev], notes
        raise ValueError(f"severity: {raw['severity']!r} not one of low|medium|high")

    # E) Ambiguous top-level `score`.
    if isinstance(raw.get("score"), (int, float)) and ambiguous is None:
        ambiguous = raw["score"]

    if ambiguous is None:
        raise ValueError("no score field found (tried score_phase4, score, overall_numeric, severity)")

    return _heuristic_scale(ambiguous, notes), notes


def _heuristic_scale(v: float, notes: list[str]) -> int:
    """Guess a 0-100 score from an ambiguously-scaled numeric.

    Bucketing (tightest-scale-first so a value of 5.0 goes to 1-5, not
    pass-through):
      - 1 <= v <= 5  → 1-5 (*20)
      - 5 <  v <= 10 → 1-10 (*10)
      - 10 <  v <= 100 → pass through
      - else → reject
    The 1-5 bucket is inclusive on both ends so exactly 5.0 maps to 100,
    matching human intuition about "top of a 1-5 scale".
    """
    f = float(v)
    if 1.0 <= f <= 5.0:
        notes.append(f"scale_inferred: ambiguous value {f} -> assumed 1-5 (*20)")
        return int(round(f * 20))
    if 5.0 < f <= 10.0:
        notes.append(f"scale_inferred: ambiguous value {f} -> assumed 1-10 (*10)")
        return int(round(f * 10))
    if 10.0 < f <= 100.0:
        notes.append(f"pass-through (in 0-100 range): {f}")
        return int(round(f))
    raise ValueError(f"numeric {v!r} out of supported range — cannot coerce to 0-100")


# ----- actionability + passthrough --------------------------------------

VALID_ACTIONABILITY = {"auto_fixable", "manual", "report_only"}
VALID_DECISION = {"confirmed", "disproven", "uncertain"}


def _actionability(raw: dict) -> tuple[str | None, list[str]]:
    notes: list[str] = []
    a = raw.get("actionability")
    if isinstance(a, str) and a in VALID_ACTIONABILITY:
        return a, notes
    if a is not None:
        notes.append(f"actionability: unknown value {a!r} discarded")
    else:
        notes.append("actionability absent")
    return None, notes


def _decision(raw: dict) -> str | None:
    d = raw.get("decision")
    if isinstance(d, str) and d in VALID_DECISION:
        return d
    return None


def canonicalize(raw: dict, lane: str) -> dict:
    """Return canonical validator-result dict. Raises ValueError on exit-2 cases."""
    score, notes = _coerce_score(raw)

    actionability, a_notes = _actionability(raw)
    notes.extend(a_notes)

    decision = _decision(raw)
    if decision is None:
        notes.append("decision absent or invalid — caller will infer from score band")

    vr = raw.get("validation_result") if lane == "deep" else None
    if lane == "deep" and vr is None:
        # Some validators emit the inner fields directly at top level.
        # If raw carries `fix_proposal` / `evidence` / `blast_radius`
        # / `verification_context` at the top level, lift them.
        lifted = {
            k: raw[k]
            for k in ("evidence", "blast_radius", "fix_proposal", "verification_context")
            if k in raw
        }
        if lifted:
            vr = lifted
            notes.append("validation_result lifted from top-level fields")

    # Schema-check the deep-lane validation_result after any top-level
    # lift. Drift (missing sub-objects, alternative keys, malformed
    # blast_radius shape) drops vr to None with an audit note rather
    # than raising — downstream `artifact-patch.py --apply-decisions`
    # would otherwise halt the whole batch on one drifted finding.
    # Light lane is unchanged (vr stays None; nothing to check).
    if lane == "deep" and vr is not None:
        if not isinstance(vr, dict):
            notes.append(
                f"validation_result shape unrecoverable: expected object, got {type(vr).__name__}"
            )
            vr = None
        else:
            try:
                validator = validation_result_validator()
                errors = list(validator.iter_errors(vr))
            except Exception as exc:  # pragma: no cover — defensive
                errors = []
                notes.append(f"validation_result schema-check skipped ({exc})")
            if errors:
                # Two sibling errors at the root (e.g. one additionalProperties
                # plus one missing-required) both report absolute_path = [],
                # so render a short message snippet alongside the path to
                # keep the note informative. First two errors only — that's
                # enough to identify the drift class in an audit trail.
                bits = []
                for e in errors[:2]:
                    p = "/".join(str(x) for x in e.absolute_path) or "(root)"
                    msg = (e.message or "").splitlines()[0][:80]
                    bits.append(f"{p}: {msg}" if msg else p)
                notes.append(
                    "validation_result shape unrecoverable: " + "; ".join(bits)
                )
                vr = None

    related = raw.get("related_candidates_to_investigate", []) if lane == "deep" else []
    if not isinstance(related, list):
        notes.append(f"related_candidates_to_investigate: expected list, got {type(related).__name__}; coerced to []")
        related = []

    return {
        "score_phase4": score,
        "actionability": actionability,
        "confirmed_strength": _strength(score),
        "decision": decision,
        "notes": "; ".join(notes) if notes else "",
        "validation_result": vr,
        "related_candidates_to_investigate": related,
    }


# ----- CLI ---------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description="Canonicalize Phase 4 validator output.")
    p.add_argument("--lane", choices=("deep", "light"), required=True,
                   help="Phase 4a (deep) or Phase 4b (light). Deep preserves validation_result.")
    args = p.parse_args()

    raw = sys.stdin.read()
    if not raw.strip():
        err_prompt(
            "empty input on stdin",
            action="pipe the validator sub-agent's raw JSON output into parse-validator-result.py.",
        )
        return EXIT_VALIDATION

    # Layer 1: parse-with-repair internally (same layering).
    from importlib.util import spec_from_file_location, module_from_spec
    # Load sibling parse-with-repair.py as a module. We re-implement the
    # call inline rather than shelling out so a single subprocess suffices
    # and so uv's dep resolution happens once.
    spec = spec_from_file_location("_pwr", Path(__file__).resolve().parent / "parse-with-repair.py")
    pwr = module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(pwr)

    try:
        obj = pwr.parse_with_repair(raw)
    except ValueError as exc:
        err_prompt(
            f"raw validator output is not parseable JSON ({exc})",
            context=[f"lane={args.lane}", f"first 200 chars: {raw[:200]!r}"],
            action="caller should route finding to `uncertain` with score_phase4=null per §13.1 Phase-4 row 1.",
        )
        return EXIT_SCORE_UNRECOVERABLE

    if not isinstance(obj, dict):
        err_prompt(
            f"validator output is {type(obj).__name__}, expected object",
            context=[f"lane={args.lane}"],
            action="inspect the validator prompt; it must return a JSON object, not array/string/number.",
        )
        return EXIT_SCORE_UNRECOVERABLE

    try:
        canonical = canonicalize(obj, args.lane)
    except ValueError as exc:
        err_prompt(
            f"cannot coerce score to 0-100 ({exc})",
            context=[f"lane={args.lane}", f"keys present: {sorted(obj.keys())}"],
            action="caller should route finding to `uncertain` with score_phase4=null per §13.1 Phase-4 row 1.",
        )
        return EXIT_SCORE_UNRECOVERABLE

    json.dump(canonical, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
