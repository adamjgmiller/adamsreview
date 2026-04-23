"""Shared helpers for adamsreview Python scripts.

This module is imported by sibling scripts in the same `bin/` directory
(notably `artifact-patch.py` and `artifact-render.py`). It is NOT a uv
inline-script itself — callers supply the uv shebang + dep spec. When
`uv run --script caller.py` runs, Python prepends the caller's directory
to sys.path, so `import _common` just works.

See docs/archive/DESIGN.md §8 (helper scripts contract), §21.2 (artifact-patch),
§24 (error recovery), and docs/archive/BUILD.md cross-stage notes (uv deviation).
"""

import difflib
import json
import os
import sys
import tempfile
from pathlib import Path


# ----- Exit codes (clarification of DESIGN §21.2) ------------------------

EXIT_OK = 0
EXIT_VALIDATION = 1          # schema / field validation error
EXIT_INVALID_TRANSITION = 2  # state-transition whitelist violation
EXIT_DRY_RUN_INVALID = 3     # --dry-run would produce invalid artifact
EXIT_UNEXPECTED = 4          # uncaught exception / unknown error
EXIT_MISSING_DEP = 5         # jsonschema import failed (shouldn't happen under uv shebang)
EXIT_USAGE = 64              # argparse / usage error (conventional)
EXIT_SCORE_UNRECOVERABLE = 2 # also used by parse-validator-result.py for score-recovery failure
EXIT_UNKNOWN_FAMILY = 3      # also used by source-family-map.py for unknown enum value


SCHEMA_PATH = Path(__file__).parent / "schema-v1.json"


# ----- Error-as-prompt ---------------------------------------------------

def err_prompt(message, valid_values=None, did_you_mean=None, action=None, context=None):
    """Emit an error-as-prompt block to stderr (DESIGN §8.6).

    Order: ERROR line, context lines (optional), valid-values (optional),
    did-you-mean (optional), action line (optional). Every line stands
    alone so a model consumer can parse without regex.
    """
    print(f"ERROR: {message}", file=sys.stderr)
    if context:
        for line in (context if isinstance(context, (list, tuple)) else [context]):
            print(str(line), file=sys.stderr)
    if valid_values:
        if isinstance(valid_values, (list, tuple)):
            print(f"Valid values: {', '.join(map(str, valid_values))}", file=sys.stderr)
        else:
            print(f"Valid values: {valid_values}", file=sys.stderr)
    if did_you_mean:
        print(f"Did you mean '{did_you_mean}'?", file=sys.stderr)
    if action:
        print(f"Action: {action}", file=sys.stderr)


def suggest(bad_value, valid_values):
    """Return the closest match from valid_values for bad_value, or None.

    Uses difflib for a more forgiving suggestion than prefix-only matching.
    Returns None when no candidate scores above the cutoff, so the caller
    can omit the did-you-mean line rather than printing nonsense.
    """
    matches = difflib.get_close_matches(str(bad_value), [str(v) for v in valid_values], n=1, cutoff=0.5)
    return matches[0] if matches else None


# ----- Schema validation -------------------------------------------------

def _load_validator():
    """Return (schema_dict, Draft202012Validator class). Exits on missing dep or missing schema."""
    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        err_prompt(
            "missing Python dependency 'jsonschema'",
            context=[
                "This script expects `uv` to resolve deps from its PEP 723 inline header.",
                "You may have invoked it with plain `python3 script.py` instead of the shebang."
            ],
            action="run `./script.py` (uses the shebang) or `uv run --script script.py`."
        )
        sys.exit(EXIT_MISSING_DEP)
    if not SCHEMA_PATH.exists():
        err_prompt(
            f"schema file not found at {SCHEMA_PATH}",
            action="verify schema-v1.json is shipped alongside this script in the plugin's bin/ directory."
        )
        sys.exit(EXIT_VALIDATION)
    with open(SCHEMA_PATH, encoding="utf-8") as f:
        schema = json.load(f)
    Draft202012Validator.check_schema(schema)
    return schema, Draft202012Validator


def validate(artifact):
    """Validate `artifact` against schema-v1.json.

    Returns a list of human-readable error strings, one per failure.
    Empty list => artifact is valid.
    """
    schema, Validator = _load_validator()
    v = Validator(schema)
    errors = []
    for e in sorted(v.iter_errors(artifact), key=lambda x: list(x.absolute_path)):
        path = _pretty_path(e.absolute_path) or "(root)"
        errors.append(f"${path}: {e.message}")
    return errors


def validation_result_validator():
    """Return a Draft202012Validator bound to `#/$defs/validation_result`.

    The sub-schema carries `{"$ref": "#/$defs/fix_proposal"}` internally; to
    keep that ref resolving we register the full schema-v1 document with a
    `referencing` Registry and validate against a `$ref` into it. The
    returned validator is suitable for `iter_errors(sub_doc)` on a
    candidate `validation_result` object.

    Used by `parse-validator-result.py` to schema-check the deep-lane
    passthrough before writing it into the artifact — drift caught here
    is dropped to None with an audit note (see that helper's docstring)
    rather than halting the Phase 4 batch downstream.
    """
    schema, Validator = _load_validator()
    try:
        from referencing import Registry, Resource
        from referencing.jsonschema import DRAFT202012
    except ImportError:
        err_prompt(
            "missing Python dependency 'referencing'",
            context=[
                "Ships transitively with jsonschema>=4.18; appears missing.",
                "This helper expects uv to resolve deps from the caller's PEP 723 header."
            ],
            action="verify the calling script's inline `# /// script` dep list includes 'jsonschema'."
        )
        sys.exit(EXIT_MISSING_DEP)
    resource = Resource(contents=schema, specification=DRAFT202012)
    registry = Registry().with_resource(uri=schema.get("$id", ""), resource=resource)
    ref_schema = {"$ref": f"{schema.get('$id', '')}#/$defs/validation_result"}
    return Validator(ref_schema, registry=registry)


def _pretty_path(absolute_path):
    """Convert jsonschema's path deque to a dotted/bracketed string.

    Integer segments render as [n]; string segments as .name.
    """
    parts = []
    for i, p in enumerate(absolute_path):
        if isinstance(p, int):
            parts.append(f"[{p}]")
        else:
            parts.append(("" if i == 0 else ".") + str(p))
    return "".join(parts)


# ----- I/O ---------------------------------------------------------------

def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def atomic_write(target, data):
    """Write JSON `data` to `target` atomically (tmp + rename).

    Temp file lives in the same directory so the rename is atomic on the
    same filesystem. Cleans up the temp file if the write raises.
    """
    target = Path(target)
    parent = target.parent
    parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=f".{target.name}.tmp.", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, target)
    except Exception:
        try:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
        except OSError:
            pass
        raise


# ----- Append-only invariants -------------------------------------------

def is_append_only(old_list, new_list):
    """True iff new_list is old_list with zero or more items appended.

    Used to enforce the append-only invariants on fix_attempts[] and
    score_history[] per DESIGN §21.2.
    """
    if not isinstance(old_list, list) or not isinstance(new_list, list):
        return False
    if len(new_list) < len(old_list):
        return False
    return new_list[: len(old_list)] == old_list


# ----- Dispositions / state coupling (DESIGN §5.2.1, §21.2) --------------

ACTIONABLE_DISPOSITIONS = frozenset({"confirmed_mechanical", "partial", "regression"})

DISPOSITION_VALUES = (
    "below_gate",
    "pending_validation",
    "disproven",
    "uncertain",
    "confirmed_mechanical",
    "confirmed_manual",
    "confirmed_report",
    "pre_existing_report",
    "partial",
    "regression",
    "resolved",
)

CURRENT_STATE_VALUES = ("open", "attempted", "resolved")

# DESIGN §5.3 transition whitelist.
ALLOWED_TRANSITIONS = {
    "open": {"attempted"},
    "attempted": {"open", "resolved"},
    "resolved": set(),  # terminal
}


def derive_is_actionable(disposition):
    """True iff disposition ∈ {confirmed_mechanical, partial, regression}."""
    return disposition in ACTIONABLE_DISPOSITIONS


def transitions_from(state):
    """Set of valid next-states from `state`. Empty for terminal states."""
    return ALLOWED_TRANSITIONS.get(state, set())
