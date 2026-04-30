#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["json-repair"]
# ///
"""parse-with-repair.py — tolerant JSON parse for sub-agent output.

Contract:
    parse-with-repair.py < input > output
      exit 0: stdout is valid JSON (repaired from input if needed)
      exit 1: input is unrecoverable even after repair (stderr: error-as-prompt)

Use cases:
- Phase 1 lens outputs, Phase 4 validator outputs, Phase 1.5 ensemble
  normalizer output — any sub-agent boundary where JSON arrives wrapped
  in ```json fences, with trailing commas, single-quoted strings, or
  unescaped newlines in string literals.

Implementation layering (first-success wins):

  1. Plain `json.loads(raw)` — happy path; no repair needed.
  2. Strip a single outer ```json ... ``` (or ``` ... ```) fence and
     retry plain `json.loads`. Covers the common "my helpful LLM wrapped
     valid JSON in a markdown fence" case without invoking repair.
  3. `json_repair.repair_json(raw, return_objects=True)` — the Python
     port of Adrien Barbaresi's jsonrepair. Handles trailing commas,
     single quotes, unquoted keys, unescaped control chars.
  4. Fence-strip + json_repair — last resort when fences co-occur with
     other slop.

Returned output is always re-serialized via stdlib `json.dumps` with
`indent=2` so downstream `jq` pipelines see canonical whitespace.

This helper is the foundation for the higher-level normalizer
parse-validator-result.py and the middle-path migration site at
fragments/02-ensemble-adapter.md. See CLAUDE.md Helper index entry.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# Make bin/_common.py importable (we're running under uv shebang so the
# script's own dir is NOT on sys.path by default — _common siblings are).
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import err_prompt, EXIT_OK, EXIT_VALIDATION  # noqa: E402


# Outer ```json ... ``` fence (greedy, case-insensitive on the tag).
# Matches the whole payload so a re-parse of the capture group is
# canonical. We don't try to be clever about nested fences.
_FENCE_RE = re.compile(
    r"^\s*```(?:json)?\s*\n?(.*?)\n?```\s*$",
    re.DOTALL | re.IGNORECASE,
)


def _strip_fence(raw: str) -> str:
    """Return `raw` with a single outer ```json ... ``` fence stripped.

    Pass-through if no fence matches. Does NOT recurse — one fence layer
    is what LLMs emit in practice; two layers would be abnormal enough
    to let the repair library handle.
    """
    m = _FENCE_RE.match(raw)
    return m.group(1) if m else raw


def parse_with_repair(raw: str):
    """Attempt strict parse → fence-strip → repair. Return parsed object.

    Raises ValueError on unrecoverable input — the CLI entry point
    translates to exit 1 + error-as-prompt.
    """
    # Layer 1: plain parse.
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        pass

    # Layer 2: fence-strip + plain parse.
    stripped = _strip_fence(raw)
    if stripped != raw:
        try:
            return json.loads(stripped)
        except json.JSONDecodeError:
            pass

    # Layer 3: repair library on raw.
    try:
        import json_repair
    except ImportError as exc:
        err_prompt(
            "missing Python dependency 'json-repair'",
            context=[
                "This script expects `uv` to resolve deps from its PEP 723 inline header.",
                "You may have invoked it with plain `python3 script.py` instead of the shebang.",
            ],
            action="run `./parse-with-repair.py` (uses the shebang) or `uv run --script parse-with-repair.py`.",
        )
        raise ValueError("json-repair unavailable") from exc

    # repair_json with return_objects=True returns the parsed Python
    # object directly (empty string on total failure). We check for that
    # degenerate case after re-serializing.
    try:
        obj = json_repair.repair_json(raw, return_objects=True)
        if obj == "" and raw.strip() != "":
            # json-repair returns "" when it completely failed to find
            # any JSON in a non-empty input. Don't accept that as a parse.
            raise ValueError("json-repair could not extract JSON")
        return obj
    except Exception:
        pass

    # Layer 4: fence-strip + repair.
    if stripped != raw:
        try:
            obj = json_repair.repair_json(stripped, return_objects=True)
            if obj == "" and stripped.strip() != "":
                raise ValueError("json-repair could not extract JSON from fence-stripped input")
            return obj
        except Exception:
            pass

    raise ValueError("unrecoverable: strict parse + fence-strip + json-repair all failed")


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        err_prompt(
            "empty input on stdin",
            action="pipe the sub-agent's raw JSON output into parse-with-repair.py.",
        )
        return EXIT_VALIDATION

    try:
        obj = parse_with_repair(raw)
    except ValueError as exc:
        err_prompt(
            f"could not parse input as JSON ({exc})",
            context=[
                "Tried: strict json.loads, fence-strip, json-repair, fence-strip+json-repair.",
                f"Input length: {len(raw)} bytes; first 200 chars: {raw[:200]!r}",
            ],
            action="inspect the upstream sub-agent's output; re-prompt for valid JSON or drop-with-note per §24.2.",
        )
        return EXIT_VALIDATION

    json.dump(obj, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
