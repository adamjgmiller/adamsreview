#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""source-family-map.py — canonicalize a lens-emitted source_family.

Contract:
    source-family-map.py --input <raw_family>
      exit 0: canonical family on stdout (single line, no trailing ws)
      exit 3: unknown family; stderr includes "UNKNOWN_FAMILY: <raw>"
      exit 64: usage error

Canonical families (eight, frozen as of 2026-04-22 — derived from
DESIGN §19 lens-output contracts + fragments/01-detection.md jq
builders):

  - diff-family          (L1)
  - structural-family    (L2, Wave 2)
  - policy-family        (L3 CLAUDE.md conformance, L4 diagnostics)
  - ux-family            (L5)
  - security-family      (L6)
  - holistic-family      (L7 ensemble)
  - external-deep-family (Phase 1.5 normalizer output)
  - external-add-family  (/adamsreview:add flow — commands/add.md
                          candidate builders for paste / structured
                          / mixed external findings)

Mapping table (drift cases from real-run trace.md inspection,
2026-04-22):

  stale-line-ref         → policy-family
  stale-behavior-claim   → policy-family
  prompt-injection       → security-family
  input-validation       → security-family
  path-traversal         → security-family
  terminal-injection     → security-family

Pass-through if the input is already canonical. Exit 3 with the
`UNKNOWN_FAMILY: <raw>` audit line on unknown — callers (Phase 1 join
step) preserve the finding but mark `source_family: "unknown"` and log
to `trace.md` so mapping drift is visible without silent drops.

Note: `fragments/01-detection.md` §1.5 step 4 inlines a parallel
canonicalization in jq for the Phase 1 hot-path; keep both tables in
sync. `test/smoke.sh` AF-DRIFT enforces agreement between this helper
and the in-jq table.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import err_prompt, EXIT_OK, EXIT_USAGE, EXIT_UNKNOWN_FAMILY  # noqa: E402


CANONICAL: frozenset[str] = frozenset({
    "diff-family",
    "structural-family",
    "policy-family",
    "ux-family",
    "security-family",
    "holistic-family",
    "external-deep-family",
    "external-add-family",
})

# Drift → canonical. Extend this table as new lens-drift patterns are
# observed in trace.md. Keys are lowercased, hyphenated; the CLI accepts
# either case but normalizes before lookup.
DRIFT_MAP: dict[str, str] = {
    # 2026-04-22 drift cases:
    "stale-line-ref":       "policy-family",
    "stale-behavior-claim": "policy-family",
    "prompt-injection":     "security-family",
    "input-validation":     "security-family",
    "path-traversal":       "security-family",
    "terminal-injection":   "security-family",

    # Common alias forms (underscore variants, plurals) seen in
    # multi-provider output.
    "stale_line_ref":       "policy-family",
    "stale_behavior_claim": "policy-family",
    "prompt_injection":     "security-family",
    "input_validation":     "security-family",
    "path_traversal":       "security-family",
    "terminal_injection":   "security-family",
}


def map_family(raw: str) -> str | None:
    """Return canonical family name or None if unknown.

    Pass-through for canonical input. Lookup in DRIFT_MAP for known
    drift. Case-insensitive comparison; whitespace-stripped input.
    """
    if not isinstance(raw, str):
        return None
    key = raw.strip().lower()
    if key in CANONICAL:
        return key
    if key in DRIFT_MAP:
        return DRIFT_MAP[key]
    return None


def main() -> int:
    p = argparse.ArgumentParser(description="Map a lens source_family to canonical.")
    p.add_argument("--input", required=True, help="Raw source_family string.")
    args = p.parse_args()

    if not args.input.strip():
        err_prompt(
            "empty --input string",
            action="pass the candidate's raw source_family value via --input.",
        )
        return EXIT_USAGE

    canonical = map_family(args.input)
    if canonical is None:
        print(f"UNKNOWN_FAMILY: {args.input}", file=sys.stderr)
        err_prompt(
            f"unknown source_family {args.input!r}",
            valid_values=sorted(CANONICAL),
            action="(Phase 1 join) preserve candidate with source_family=\"unknown\" and log drift to trace.md.",
        )
        return EXIT_UNKNOWN_FAMILY

    print(canonical)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
