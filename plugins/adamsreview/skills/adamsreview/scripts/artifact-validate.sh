#!/usr/bin/env bash
# artifact-validate.sh — schema validation for artifact.json (DESIGN §8.3, §21.3).
#
# Thin Bash wrapper that invokes _common.validate() via `uv run --with
# jsonschema python3 -` with a heredoc script. This keeps the whole
# validator in one .sh file (matching the DESIGN §9.1 layout) without
# a separate .py companion.
#
# Usage:
#   artifact-validate.sh --path <artifact.json>
#
# Exits:
#   0   valid
#   1   schema violations (printed to stderr, one per line)
#   64  usage error (missing --path, unknown flag)

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --path <artifact.json>

Validate an adamsreview artifact against schema-v1.json.
Exits 0 if valid; 1 with violations to stderr if invalid.
USAGE
}

die_usage() {
    echo "ERROR: $1" >&2
    usage
    exit 64
}

ARTIFACT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            [[ -n "${2:-}" ]] || die_usage "--path requires a value"
            ARTIFACT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die_usage "unknown arg '$1'"
            ;;
    esac
done

[[ -n "$ARTIFACT" ]] || die_usage "--path is required"

if [[ ! -f "$ARTIFACT" ]]; then
    echo "ERROR: artifact not found at $ARTIFACT" >&2
    echo "Action: check the path, or run artifact-patch.py --init first." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PYTHONPATH="$SCRIPT_DIR" uv run --with jsonschema python3 - "$ARTIFACT" <<'PY'
import json, sys
import _common as c

try:
    artifact = json.load(open(sys.argv[1]))
except json.JSONDecodeError as e:
    print(f"ERROR: {sys.argv[1]} is not valid JSON: {e.msg} (line {e.lineno}, col {e.colno})", file=sys.stderr)
    print("Action: restore from git or re-run artifact-patch.py --init.", file=sys.stderr)
    sys.exit(1)

errs = c.validate(artifact)
if errs:
    print(f"ERROR: {sys.argv[1]} has {len(errs)} schema violation(s):", file=sys.stderr)
    for e in errs:
        print(f"  {e}", file=sys.stderr)
    sys.exit(1)
print(f"valid: {sys.argv[1]}")
PY
