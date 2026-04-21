#!/usr/bin/env bash
# assign-finding-ids.sh — deterministic finding-id assignment over a
# pooled candidate set (DESIGN §13.12).
#
# Used at the Phase 1 + Phase 1.5 join point: after every internal lens
# has returned and (under --ensemble) the Sonnet normalizer has emitted
# its candidate array, the orchestrator combines the two pools into one
# array and pipes it here. This helper sorts by source priority (stable
# within source = preserves input order), then assigns F001..F0NN.
#
# Usage:
#   assign-finding-ids.sh < pooled_candidates.json
#   echo "$pooled" | assign-finding-ids.sh
#
# Stdin:  JSON array of candidate objects. Each element must have a
#         `sources` array; the helper reads `sources[0]` to bucket into
#         a priority class. Elements with an empty/missing `sources`
#         array, or a source string not on the known list, fall to
#         priority 99 (sorted last; still gets an id).
#
# Stdout: same array (same post-sort element order) with `.id` set to
#         F001, F002, ... (zero-padded to 3 digits) in sort order.
#
# Source priority order (matches per-lens dispatch sequencing in
# 01-detection.md step 1.3):
#
#   1  L1-diff-local
#   2  L2-structural
#   3  L3-claude-md
#   4  L4-comments
#   5  L5-ux
#   6  L6-security
#   7  L7-holistic
#   8  external-pr:<author_login>  (sub-ordered by author_login)
#   9  codex
#   10 coderabbit
#   99 unknown (forward-compat)
#
# Exits: 0 success; 1 stdin is not a JSON array.

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: assign-finding-ids.sh < pooled_candidates.json

Stdin:  JSON array of candidate objects; each element should have
        a `sources` array (`sources[0]` drives the priority sort).
Stdout: the same array (sorted) with `.id` set to F001..F0NN.
USAGE
}

# --help / -h surface the usage and exit 0.
if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unexpected arg '$1'" >&2; usage; exit 64 ;;
    esac
fi

input=$(cat)

if ! printf '%s' "$input" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "ERROR: stdin is not a JSON array." >&2
    echo "  Valid input: JSON array of candidate objects (pooled from Phase 1 + Phase 1.5)." >&2
    echo "  Did you mean: pipe the combined pool, e.g. 'echo \"\$internal\" | jq \"\$internal + \$external\" | assign-finding-ids.sh'?" >&2
    echo "  Action: check that the upstream \$internal_candidates / \$external_candidates are valid JSON arrays and concatenate them before piping." >&2
    exit 1
fi

# Sort strategy: bucket by numeric source priority (primary key), then
# by input-array position (secondary key = stable sort). jq's sort_by
# is stable as of 1.6, which matches every platform we target.
#
# external-pr:* entries share bucket 7 but sub-sort by sources[0] string
# so distinct bot logins land in a deterministic order.
printf '%s' "$input" | jq -c '
  def src_priority:
    (.sources // []) | (if length == 0 then "" else .[0] end) as $s |
    if   $s == "L1-diff-local" then 1
    elif $s == "L2-structural" then 2
    elif $s == "L3-claude-md"  then 3
    elif $s == "L4-comments"   then 4
    elif $s == "L5-ux"         then 5
    elif $s == "L6-security"   then 6
    elif $s == "L7-holistic"   then 7
    elif ($s | startswith("external-pr:")) then 8
    elif $s == "codex"         then 9
    elif $s == "coderabbit"    then 10
    else 99 end;

  def src_subkey:
    (.sources // []) | (if length == 0 then "" else .[0] end);

  to_entries
  | map(.value + {_idx: .key, _pri: (.value | src_priority), _sub: (.value | src_subkey)})
  | sort_by(._pri, ._sub, ._idx)
  | to_entries
  | map(
      .value + {
        id: ("F" + (((.key) + 1) | tostring | "000" + . | .[-3:]))
      }
      | del(._idx, ._pri, ._sub)
    )
'
