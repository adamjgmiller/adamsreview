#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["jsonschema"]
# ///
"""group-fixes.py — union-find fix grouping for Phase 8 (DESIGN §21.5).

Input: a validated artifact + a list of eligible finding ids (the
orchestrator is responsible for filtering per §4 Phase 8: current_state
== "open", disposition ∈ {confirmed_mechanical, partial, regression},
impact_type ∈ {correctness, security}, score_phase4 >= threshold).
This helper does NOT re-derive eligibility — it validates that the ids
it was given satisfy the prerequisites for grouping and then merges
them into fix groups.

Algorithm (§21.5):
  1. Build id → finding index for every eligible id.
  2. Seed groups with the cross_cutting_groups from the artifact — any
     cross-cutting group that overlaps the eligible set has its eligible
     members merged.
  3. For each pair of eligible findings whose
     validation_result.fix_proposal.files_to_modify[].file sets intersect,
     merge them.
  4. Compact to components. Assign FG-1, FG-2, … deterministically
     ordered by each component's minimum-numeric-id finding.
  5. Emit JSON array: [{id, finding_ids, files_planned}, ...].

Output invariants:
  - finding_ids inside each group sorted by numeric id (F001 < F010).
  - files_planned sorted alphabetically.
  - FG-N ordering deterministic across runs: same input → same output.

Error cases (all via error-as-prompt per DESIGN §8.6):
  - Unknown eligible id → EXIT_VALIDATION (1).
  - Eligible finding has current_state != "open" or disposition outside
    {confirmed_mechanical, partial, regression} → EXIT_VALIDATION (1).
  - Eligible finding missing validation_result.fix_proposal.files_to_modify
    → EXIT_VALIDATION (1).
  - Malformed artifact (schema violation) → EXIT_VALIDATION (1).
  - Unreadable --artifact path → EXIT_VALIDATION (1).

--eligible-finding-ids accepts:
  - CSV inline:        F001,F002,F003
  - file (@<path>):    one id per line
  - stdin (-):         one id per line (newline- or comma-separated — both work)
"""

import argparse
import json
import re
import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import _common as c  # noqa: E402


# ----- Input parsing -----------------------------------------------------

_ELIGIBLE_DISPOSITIONS = frozenset({"confirmed_mechanical", "partial", "regression"})


def _parse_eligible_ids(value):
    """Parse the --eligible-finding-ids argument into an ordered list.

    Supports CSV inline, @<path> file, or `-` for stdin. Whitespace and
    newlines are treated as separators in all sources. Empty and
    duplicate ids are dropped; order of first occurrence is preserved.
    """
    if value == "-":
        raw = sys.stdin.read()
        source = "<stdin>"
    elif value.startswith("@"):
        path = value[1:]
        try:
            with open(path) as f:
                raw = f.read()
            source = path
        except OSError as e:
            c.err_prompt(
                f"could not read --eligible-finding-ids from {path}: {e}",
                action="pass a CSV inline, @<path> for a file, or - for stdin."
            )
            sys.exit(c.EXIT_USAGE)
    else:
        raw = value
        source = "<inline>"

    # Split on any whitespace or comma. re.split handles both.
    tokens = [t for t in re.split(r"[\s,]+", raw) if t]

    # Preserve first-occurrence order while deduping.
    seen = set()
    ordered = []
    for t in tokens:
        if t not in seen:
            seen.add(t)
            ordered.append(t)

    if not ordered:
        # Empty list is legitimate — orchestrator passes zero eligible
        # findings when the threshold filter excludes everything. Return
        # empty list; main() emits "[]" and exits 0.
        return []

    # Shape check: ids must match ^F[0-9]+$ (same regex schema uses).
    bad = [t for t in ordered if not re.fullmatch(r"F[0-9]+", t)]
    if bad:
        c.err_prompt(
            f"--eligible-finding-ids contains malformed ids from {source}: {bad}",
            action="ids must match ^F[0-9]+$ (e.g. F001, F042)."
        )
        sys.exit(c.EXIT_USAGE)

    return ordered


# ----- Finding eligibility checks ---------------------------------------

def _check_eligible(finding, fid):
    """Validate that the caller-supplied eligible finding is actually groupable.

    The orchestrator owns the score / threshold / impact_type filter
    (§4 Phase 8); this helper just asserts that the finding is in an
    appropriate state for Phase 8 AND has the fix_proposal shape we need
    for file-union grouping. Emits error-as-prompt and sys.exits on
    failure.
    """
    if finding.get("current_state") != "open":
        c.err_prompt(
            f"finding {fid}: current_state='{finding.get('current_state')}' is not eligible for Phase 8 grouping",
            context="Phase 8 eligibility requires current_state=='open' (§4 Phase 8). Leftover-attempted findings trigger a hard abort in Phase 7 before this helper runs.",
            action="check the Phase 7 eligibility filter in 09-fix-execution.md step 8.1."
        )
        sys.exit(c.EXIT_VALIDATION)

    disp = finding.get("disposition")
    if disp not in _ELIGIBLE_DISPOSITIONS:
        c.err_prompt(
            f"finding {fid}: disposition='{disp}' is not eligible for Phase 8 grouping",
            valid_values=sorted(_ELIGIBLE_DISPOSITIONS),
            action="only {confirmed_mechanical, partial, regression} findings participate in fix groups."
        )
        sys.exit(c.EXIT_VALIDATION)

    vr = finding.get("validation_result")
    promoted = finding.get("human_confirmation") is not None
    if not isinstance(vr, dict):
        if promoted:
            # Promoted findings (§27) may have null validation_result when
            # they came from Phase 4b (light lane) or from Phase 4a with a
            # non-confirmed decision. The human override bypasses Phase 4's
            # fix_proposal requirement; the grouper falls back to
            # finding.file as the single planned file (see _files_planned).
            return
        c.err_prompt(
            f"finding {fid}: validation_result is required for fix grouping (got {type(vr).__name__ if vr is not None else 'null'})",
            context="Phase 4 deep-lane validators populate validation_result. confirmed_mechanical findings without one would have failed schema validation earlier — so this usually means a fixture or a stale patch.",
            action="re-run /adamsreview:review to refresh validation_result, or exclude this finding from --eligible-finding-ids. (Promoted findings with null validation_result are accepted — this one is not promoted.)"
        )
        sys.exit(c.EXIT_VALIDATION)

    fp = vr.get("fix_proposal")
    if not isinstance(fp, dict):
        if promoted:
            return
        c.err_prompt(
            f"finding {fid}: validation_result.fix_proposal is missing",
            action="the validator's fix_proposal.files_to_modify drives the file-union grouping; a finding without it cannot be grouped. (Promoted findings bypass this requirement — this one is not promoted.)"
        )
        sys.exit(c.EXIT_VALIDATION)

    ftm = fp.get("files_to_modify")
    if not isinstance(ftm, list):
        c.err_prompt(
            f"finding {fid}: validation_result.fix_proposal.files_to_modify must be a list (got {type(ftm).__name__})",
            action="schema requires this field — re-run /adamsreview:review if the artifact is malformed."
        )
        sys.exit(c.EXIT_VALIDATION)


def _files_planned(finding):
    """Return the sorted unique list of files this finding plans to touch.

    Primary source: validation_result.fix_proposal.files_to_modify[].file.
    For promoted findings (§27) with null validation_result or missing
    fix_proposal, falls back to [finding.file] — a single-file plan
    targeting just the finding's own location. Deduped and sorted so
    comparisons and output are deterministic.
    """
    vr = finding.get("validation_result") or {}
    fp = vr.get("fix_proposal") or {}
    ftm = fp.get("files_to_modify") or []
    files = {e.get("file") for e in ftm if isinstance(e, dict) and e.get("file")}
    if not files:
        fallback = finding.get("file")
        if fallback:
            files = {fallback}
    return sorted(files)


# ----- Union-find --------------------------------------------------------

class _UnionFind:
    """Tiny path-compressing union-find. Keys are finding ids (strings)."""

    def __init__(self, keys):
        self._parent = {k: k for k in keys}

    def find(self, k):
        # Iterative path compression.
        root = k
        while self._parent[root] != root:
            root = self._parent[root]
        # Compress.
        cur = k
        while self._parent[cur] != root:
            nxt = self._parent[cur]
            self._parent[cur] = root
            cur = nxt
        return root

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra == rb:
            return
        self._parent[ra] = rb

    def components(self):
        """Map root → sorted list of member keys."""
        comps = {}
        for k in self._parent:
            r = self.find(k)
            comps.setdefault(r, []).append(k)
        return comps


# ----- Core algorithm ----------------------------------------------------

_ID_RE = re.compile(r"^F(\d+)$")


def _id_sort_key(fid):
    """Sort key for F001 < F010 < F100 — numeric, not lexicographic."""
    m = _ID_RE.match(fid)
    return int(m.group(1)) if m else 10 ** 9


def _compute_groups(artifact, eligible_ids):
    """Compute fix groups for the eligible set. Returns list of dicts."""
    findings_by_id = {f.get("id"): f for f in artifact.get("findings", [])}

    # Fail loud on unknown ids — orchestrator must not guess.
    unknown = [fid for fid in eligible_ids if fid not in findings_by_id]
    if unknown:
        existing = sorted(findings_by_id.keys(), key=_id_sort_key)
        c.err_prompt(
            f"--eligible-finding-ids references unknown id(s): {unknown}",
            valid_values=f"existing ids: {existing}" if existing else "no findings in this artifact",
            did_you_mean=c.suggest(unknown[0], existing) if existing else None,
            action="re-run /adamsreview:review or fix the orchestrator's eligibility filter."
        )
        sys.exit(c.EXIT_VALIDATION)

    # Per-finding eligibility shape check (current_state/disposition/fix_proposal).
    for fid in eligible_ids:
        _check_eligible(findings_by_id[fid], fid)

    if not eligible_ids:
        return []

    uf = _UnionFind(eligible_ids)
    eligible_set = set(eligible_ids)

    # Step A — seed from cross_cutting_groups. Any CCG that intersects the
    # eligible set merges its eligible members.
    for ccg in artifact.get("cross_cutting_groups", []):
        members = [fid for fid in ccg.get("finding_ids", []) if fid in eligible_set]
        if len(members) >= 2:
            anchor = members[0]
            for m in members[1:]:
                uf.union(anchor, m)

    # Step B — union by shared planned file. Build file-sets once.
    planned = {fid: set(_files_planned(findings_by_id[fid])) for fid in eligible_ids}

    # Invert the files→ids map so we touch O(N + total_file_refs) instead
    # of O(N^2) for the all-pairs comparison. Two findings listing the
    # same file land in the same bucket and get unioned once.
    file_buckets = {}
    for fid in eligible_ids:
        for f in planned[fid]:
            file_buckets.setdefault(f, []).append(fid)
    for f, ids in file_buckets.items():
        if len(ids) >= 2:
            anchor = ids[0]
            for other in ids[1:]:
                uf.union(anchor, other)

    # Step C — compact + assign FG-N in deterministic order.
    comps = uf.components()
    # Order components by their minimum numeric id for a stable FG numbering.
    ordered_comps = sorted(
        comps.values(),
        key=lambda members: min(_id_sort_key(m) for m in members)
    )

    groups = []
    for idx, members in enumerate(ordered_comps, start=1):
        sorted_members = sorted(members, key=_id_sort_key)
        files_union = set()
        for m in sorted_members:
            files_union |= planned[m]
        groups.append({
            "id": f"FG-{idx}",
            "finding_ids": sorted_members,
            "files_planned": sorted(files_union),
        })

    return groups


# ----- CLI ---------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        prog="group-fixes.py",
        description="Union-find fix grouping for Phase 8 (DESIGN §21.5)."
    )
    p.add_argument(
        "--artifact",
        required=True,
        help="path to artifact.json (absolute recommended)"
    )
    p.add_argument(
        "--eligible-finding-ids",
        required=True,
        metavar="IDS",
        help="CSV of finding ids, @<path> for a file of ids, or - for stdin (comma or newline separated)"
    )
    p.add_argument(
        "--output-json",
        action="store_true",
        default=True,
        help="(default) emit JSON array of groups to stdout"
    )
    return p


def main():
    parser = build_parser()
    args = parser.parse_args()

    try:
        artifact = c.read_json(args.artifact)
    except FileNotFoundError:
        c.err_prompt(
            f"artifact not found at {args.artifact}",
            action="check --artifact; run `/adamsreview:review` if this branch has no review."
        )
        return c.EXIT_VALIDATION
    except json.JSONDecodeError as e:
        c.err_prompt(
            f"artifact at {args.artifact} is not valid JSON: {e.msg} (line {e.lineno}, col {e.colno})",
            action="the on-disk file is corrupted — restore from git or re-run /adamsreview:review."
        )
        return c.EXIT_VALIDATION

    errors = c.validate(artifact)
    if errors:
        shown = errors[:10]
        overflow = [f"  (+{len(errors) - 10} more)"] if len(errors) > 10 else []
        c.err_prompt(
            f"artifact is invalid ({len(errors)} schema violation(s))",
            context=["  " + e for e in shown] + overflow,
            action="re-run /adamsreview:review to regenerate a valid artifact."
        )
        return c.EXIT_VALIDATION

    eligible_ids = _parse_eligible_ids(args.eligible_finding_ids)
    groups = _compute_groups(artifact, eligible_ids)

    json.dump(groups, sys.stdout)
    sys.stdout.write("\n")
    return c.EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:
        c.err_prompt(
            f"unexpected error: {type(e).__name__}: {e}",
            action="this is a bug; full traceback follows below."
        )
        traceback.print_exc(file=sys.stderr)
        sys.exit(c.EXIT_UNEXPECTED)
