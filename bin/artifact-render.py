#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["jsonschema"]
# ///
"""artifact-render.py — JSON artifact → Markdown report (DESIGN §7, §21.6).

Section selectors filter on `disposition` (§5.2.1), so report counts
are deterministic derivations from the same machine-readable field
Phase 8 eligibility uses. The first line of the output is the stable
HTML-comment marker so artifact-publish.sh can locate prior PR
comments regardless of review_id (§13.4).

Usage:
  artifact-render.py --input <artifact.json> [--output <artifact.md>]

If --output is omitted, Markdown goes to stdout.
"""

import argparse
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import _common as c  # noqa: E402


MARKER = "<!-- adams-review-v1 -->"

# Disposition → (section ordering key, section label, glyph, short label).
# `section label` titles sections; `short label` appears in summary bullets and
# the Light-lane Disposition cell. Raw enum values never appear in rendered
# output — they stay machine-facing in artifact.json.
#
# `bin/schema-v1.json` defines 11 disposition enum values; the 8 mapped here
# are all the ones that render into actionable / report sections. The three
# omitted on purpose are:
#   - `disproven`         — Phase-4 rejected, surfaced via the summary's
#                           "Filtered out" bullet, no per-finding section.
#   - `below_gate`        — Phase-3 nit, surfaced via summary "Filtered out"
#                           + optional `render_polish_clusters` table.
#   - `pending_validation` — Phase-1 parking value; should never survive past
#                           Phase 6 finalize. If it leaks through, the
#                           Uncategorized residual bullet in render_summary
#                           surfaces it rather than silently absorbing the
#                           count. Any future enum addition lands the same
#                           way until SECTION_LABEL + render_summary are
#                           extended.
SECTION_LABEL = {
    "confirmed_mechanical": ("01", "Auto-fixable", "✓", "auto-fixable"),
    "confirmed_manual": ("02", "Requires manual attention", "⚠", "manual"),
    "uncertain": ("03", "Uncertain", "ℹ", "uncertain"),
    "confirmed_report": ("04", "Confirmed — informational", "ℹ", "informational"),
    "pre_existing_report": ("05", "Pre-existing — report-only", "ℹ", "pre-existing"),
    "partial": ("06", "Partially fixed (retry-eligible)", "⚠", "partial"),
    "regression": ("07", "Regression (reverted; retry-eligible)", "✗", "regression"),
    "resolved": ("08", "Resolved", "✓", "resolved"),
}

DEEP_AUTO_FIX_DISPOSITIONS = ("confirmed_mechanical", "partial", "regression", "resolved")


# ----- Helpers ----------------------------------------------------------

def findings_by_disposition(artifact):
    buckets = defaultdict(list)
    for f in artifact.get("findings", []):
        buckets[f.get("disposition")].append(f)
    return buckets


def format_line_range(lr):
    if not lr:
        return ""
    if len(lr) == 2 and lr[0] == lr[1]:
        return f":{lr[0]}"
    if len(lr) == 2:
        return f":{lr[0]}-{lr[1]}"
    return ""


def file_link(finding):
    return f"`{finding.get('file', '?')}{format_line_range(finding.get('line_range'))}`"


def any_fix_attempts(artifact):
    return any(f.get("fix_attempts") for f in artifact.get("findings", []))


def latest_attempt(finding):
    attempts = finding.get("fix_attempts") or []
    return attempts[-1] if attempts else None


def status_cell(finding):
    """Return the post-fix Status column cell for a deep-auto finding."""
    att = latest_attempt(finding)
    if not att:
        return ""
    outcome = att.get("phase_9_outcome")
    sha = att.get("output_sha")
    sha_link = f"`{sha[:7]}`" if sha else "(no commit)"
    if outcome == "verified":
        return f"✓ fixed and verified ({sha_link})"
    if outcome == "partial":
        return f"⚠ partial ({sha_link})"
    if outcome == "regression":
        return f"✗ regression (reverted)"
    if outcome is None:
        return "—"
    return str(outcome)


def thousands(n):
    try:
        return f"{int(n):,}"
    except (TypeError, ValueError):
        return str(n)


def _clustered_below_gate(buckets):
    """Return {file_path: [sorted_clustered_findings]} for below_gate findings.

    Shared by `render_summary` (to split the "Filtered out" bullet between
    findings that surface in a polish cluster vs. those that don't) and
    `render_polish_clusters` (to render the table). Detection rule: per
    file, any sliding window of ≥3 below_gate findings whose `line_range[0]`
    span is ≤ 100 lines produces a cluster; findings inside at least one
    such window get included. Findings without a usable `line_range[0]` are
    skipped — they can't anchor a cluster.
    """
    below = [f for f in buckets.get("below_gate", [])
             if (f.get("line_range") or [0])[0]]
    if len(below) < 3:
        return {}

    by_file = defaultdict(list)
    for f in below:
        by_file[f.get("file") or "?"].append(f)

    clustered_by_file = {}
    for file_path, ffs in by_file.items():
        if len(ffs) < 3:
            continue
        sorted_ffs = sorted(ffs, key=lambda f: (f.get("line_range") or [0])[0])
        in_cluster = set()
        left = 0
        for right in range(len(sorted_ffs)):
            right_line = (sorted_ffs[right].get("line_range") or [0])[0]
            while (right_line - (sorted_ffs[left].get("line_range") or [0])[0]) > 100:
                left += 1
            if right - left + 1 >= 3:
                for i in range(left, right + 1):
                    in_cluster.add(i)
        if in_cluster:
            clustered_by_file[file_path] = [sorted_ffs[i] for i in sorted(in_cluster)]
    return clustered_by_file


# ----- Section renderers ------------------------------------------------

def render_freshness_line(artifact):
    """Return the base-freshness header line per §13.10, or '' when omitted.

    Absent for `fresh`, `no_remote`, or missing `base_context` (pre-§13.10
    artifacts). The warning glyphs escalate by severity: fast_forwarded
    reports the prior behind count as context, used_remote_ref flags that
    the review used the remote ref, proceeded_stale flags data loss.
    """
    bc = artifact.get("base_context") or {}
    freshness = bc.get("freshness")
    if not freshness or freshness in ("fresh", "no_remote"):
        return ""
    base = artifact.get("base_branch", "?")
    behind = bc.get("behind_count")
    behind_phrase = f"{behind} commits behind" if behind else "behind"
    if freshness == "fast_forwarded":
        return (f"**Base freshness:** local `{base}` was {behind_phrase} "
                f"`origin/{base}` at run start; fast-forwarded before review")
    if freshness == "used_remote_ref":
        return (f"**Base freshness:** ⚠ local `{base}` is {behind_phrase} "
                f"`origin/{base}`; this review compared against "
                f"`origin/{base}` instead")
    if freshness == "proceeded_stale":
        return (f"**Base freshness:** ⚠⚠ compared against stale local `{base}` "
                f"({behind_phrase} `origin/{base}`). Re-run after `git pull` "
                f"for accurate results.")
    if freshness == "no_fetch":
        return (f"**Base freshness:** could not fetch `origin/{base}` "
                f"(offline?); compared against local `{base}`")
    # Unknown freshness values — should be caught by schema validation, but
    # render a best-effort line rather than silently dropping.
    return f"**Base freshness:** `{freshness}` (see trace.md)"


def render_header(artifact):
    lines = []
    head = artifact.get("head_branch", "?")
    base = artifact.get("base_branch", "?")
    lines.append("### Code review")
    lines.append("")
    lines.append(f"**Branch:** `{head}` → `{base}`")
    if artifact.get("mode") == "pr" and artifact.get("pr_number"):
        pr_state = artifact.get("pr_state")
        suffix = f" ({pr_state})" if pr_state else ""
        lines.append(f"**PR:** #{artifact['pr_number']}{suffix}")
    else:
        lines.append("**Mode:** local")
    lines.append(f"**Review ID:** `{artifact.get('review_id', '?')}`")
    freshness_line = render_freshness_line(artifact)
    if freshness_line:
        lines.append(freshness_line)
    if not any_fix_attempts(artifact):
        lines.append("**Fix threshold:** not yet set (run `/adamsreview:fix [threshold]` to apply fixes)")
    tokens = artifact.get("subagent_tokens") or {}
    total = tokens.get("total")
    invs = tokens.get("invocations")
    if total is not None and invs is not None:
        lines.append(f"**Sub-agent tokens:** {thousands(total)} across {thousands(invs)} invocations")
    orch = artifact.get("orchestrator_tokens") or {}
    turn_count = orch.get("turn_count")
    # Suppress on missing AND on zero-turn. Missing means the helper
    # hasn't run (pre-feature artifacts, or opted-out runs since the
    # ADAMS_REVIEW_TALLY_ORCHESTRATOR opt-in landed). Zero-turn means
    # either a legacy artifact carrying the dropped Phase-0 zero seed,
    # or an opted-in run whose time window matched no turns — both
    # render as content-free noise. The four counters stay in the
    # artifact when present (see OTR-3); only the rendered line is
    # gated. Render shows only output + fresh input — cache-read and
    # cache-creation are prompt-cache plumbing, not user-facing signal
    # (see CLAUDE.md §"Pipeline shape" for the rationale).
    if turn_count:
        lines.append(
            "**Orchestrator tokens:** "
            f"{thousands(orch.get('total_output', 0))} output / "
            f"{thousands(orch.get('total_input', 0))} input "
            f"across {thousands(turn_count)} turns"
        )
    if artifact.get("trivial_mode"):
        lines.append("**Trivial mode:** on (downshifted pipeline per §13.9)")
    return "\n".join(lines)


def render_summary(buckets):
    findings_count = sum(len(v) for v in buckets.values())
    if findings_count == 0:
        return "No findings."

    deep = lambda k: [f for f in buckets.get(k, []) if f.get("validation_lane") == "deep"]
    light = lambda k: [f for f in buckets.get(k, []) if f.get("validation_lane") == "light"]

    deep_bits = []
    for disp in ("confirmed_mechanical", "partial", "regression", "resolved",
                 "confirmed_manual", "confirmed_report", "uncertain"):
        n = len(deep(disp))
        if n:
            deep_bits.append(f"{n} {SECTION_LABEL[disp][3]}")

    light_bits = []
    # `uncertain` included: §13.1 Phase-4 rule "score 45-59 → uncertain" applies
    # regardless of lane. Light-lane uncertain findings were silently dropped
    # from both this summary and render_light_lane's table prior to Stage 2.5.D —
    # the C13 ray-finance run quietly lost 3 findings from its PR comment.
    # `partial` / `regression` / `resolved` included for lane symmetry with
    # deep_bits: a light-lane finding promoted via :promote and then run through
    # :fix can land in any of these states, and would otherwise drop from the
    # summary count (same Xilem #1791 silent-drop class).
    for disp in ("confirmed_mechanical", "partial", "regression", "resolved",
                 "confirmed_manual", "confirmed_report", "uncertain"):
        n = len(light(disp))
        if n:
            light_bits.append(f"{n} {SECTION_LABEL[disp][3]}")

    pre_existing_n = len(buckets.get("pre_existing_report", []))

    # Findings the renderer doesn't put in an actionable lane table: Phase 4
    # rejected them (disproven) or Phase 3 scored them under the gate
    # (below_gate). Pre-fix, these counted toward findings_count but had no
    # bullet — readers saw "Found 9" but only 2 listed, with no accounting
    # for the missing 7. Lane symmetry (light_bits now mirrors deep_bits) +
    # the Uncategorized residual below close the full silent-drop class
    # (deep & light fix-state dropouts, disproven, below_gate, and any
    # future disposition enum value or stray pending_validation).
    #
    # below_gate is split: findings surfaced by render_polish_clusters
    # appear visibly downstream, so labeling them "filtered out" without
    # qualification contradicts the polish table. The split bullet keeps
    # the headline label honest while preserving the "<45" affordance.
    filtered_bits = []
    disproven_n = len(buckets.get("disproven", []))
    below_gate_findings = buckets.get("below_gate", [])
    below_gate_n = len(below_gate_findings)
    # Count from the cluster dict directly rather than via an ID set:
    # schema doesn't enforce uniqueness of `findings[].id`, so an
    # ID-membership check could miscount a non-clustered finding that
    # shares an ID with a clustered one (defensive; artifact-patch.py
    # rejects duplicates on add/set, but hand-edited or third-party
    # writers could land here).
    below_gate_clustered = sum(
        len(v) for v in _clustered_below_gate(buckets).values()
    )
    below_gate_filtered = below_gate_n - below_gate_clustered
    if disproven_n:
        filtered_bits.append(f"{disproven_n} disproven")
    if below_gate_n:
        if below_gate_clustered and below_gate_filtered:
            filtered_bits.append(
                f"{below_gate_filtered} below score gate (<45); "
                f"{below_gate_clustered} surfaced in Polish clusters below"
            )
        elif below_gate_clustered:
            filtered_bits.append(
                f"{below_gate_clustered} below score gate (<45), "
                "surfaced in Polish clusters below"
            )
        else:
            filtered_bits.append(f"{below_gate_n} below score gate (<45)")

    lines = [f"Found {findings_count} finding{'s' if findings_count != 1 else ''} across all lanes:"]
    if deep_bits:
        lines.append(f"- Deep lane (correctness/security): {', '.join(deep_bits)}")
    if light_bits:
        lines.append(f"- Light lane (ux/policy/architecture): {', '.join(light_bits)}")
    if pre_existing_n:
        lines.append(f"- Pre-existing (high-confidence origin, report-only): {pre_existing_n}")
    if filtered_bits:
        lines.append(f"- Filtered out: {', '.join(filtered_bits)}")

    # Uncategorized residual: any finding whose disposition isn't covered by
    # the bullets above counts here. In steady state this is 0 — the pipeline
    # intends `pending_validation` not to survive past Phase 6, and Phase 4
    # overwrites every `pending_validation` survivor with a Phase-4 disposition
    # — but the schema still allows the enum value (no finalize-time assert
    # rejects it). This bullet is the safety net: rendering it whenever the
    # sum doesn't reconcile prevents the silent-drop class from re-emerging
    # if a `pending_validation` finding leaks through or a future disposition
    # enum value lands without a corresponding renderer update. See
    # SECTION_LABEL header comment for the catalog of intentionally-omitted
    # dispositions.
    deep_accounted = sum(len(deep(d)) for d in (
        "confirmed_mechanical", "partial", "regression", "resolved",
        "confirmed_manual", "confirmed_report", "uncertain",
    ))
    light_accounted = sum(len(light(d)) for d in (
        "confirmed_mechanical", "partial", "regression", "resolved",
        "confirmed_manual", "confirmed_report", "uncertain",
    ))
    accounted_total = (
        deep_accounted + light_accounted + pre_existing_n + disproven_n + below_gate_n
    )
    uncategorized_n = findings_count - accounted_total
    if uncategorized_n > 0:
        lines.append(f"- Uncategorized: {uncategorized_n}")

    return "\n".join(lines)


def render_deep_auto(buckets, cross_cutting_groups):
    rows = []
    for disp in DEEP_AUTO_FIX_DISPOSITIONS:
        for f in buckets.get(disp, []):
            if f.get("validation_lane") == "deep":
                rows.append(f)
    # Sort by finding id so the table order is stable across dispositions
    # (otherwise a partial F003 would appear before a resolved F001 just
    # because the disposition order happens that way).
    rows.sort(key=lambda f: f.get("id", ""))
    if not rows:
        return ""

    show_status = any(f.get("fix_attempts") for f in rows)

    lines = []
    lines.append(f"### ✓ Auto-fixable ({len(rows)})")
    lines.append("")
    if show_status:
        lines.append("| # | Score | Impact | File | Issue | Status |")
        lines.append("|---|-------|--------|------|-------|--------|")
        for f in rows:
            lines.append(
                f"| {f.get('id')} | {f.get('score_phase4') or f.get('score_phase3') or ''} | "
                f"{f.get('impact_type', '?')} | {file_link(f)} | {_claim_with_promotion(f)} | "
                f"{status_cell(f)} |"
            )
    else:
        lines.append("| # | Score | Impact | File | Issue |")
        lines.append("|---|-------|--------|------|-------|")
        for f in rows:
            lines.append(
                f"| {f.get('id')} | {f.get('score_phase4') or f.get('score_phase3') or ''} | "
                f"{f.get('impact_type', '?')} | {file_link(f)} | {_claim_with_promotion(f)} |"
            )

    # Cross-cutting group callouts that include any of our rows.
    row_ids = {f.get("id") for f in rows}
    callouts = []
    for g in cross_cutting_groups:
        members_here = [fid for fid in g.get("finding_ids", []) if fid in row_ids]
        if len(members_here) >= 2:
            callouts.append(
                f"**Cross-cutting group {g.get('id')}:** {' + '.join(members_here)} — {g.get('combined_approach', '')}"
            )
    if callouts:
        lines.append("")
        lines.extend(callouts)

    # Details block; separate per-finding blocks with blank lines.
    lines.append("")
    lines.append("<details><summary>Details and fix proposals</summary>")
    for detail in (_finding_detail(f) for f in rows):
        lines.append("")
        lines.append(detail)
    lines.append("")
    lines.append("</details>")

    return "\n".join(lines)


def _claim_with_promotion(f):
    """Claim cell for finding tables, suffixed with (human-confirmed) tag when promoted."""
    claim = f.get("claim", "")
    if f.get("human_confirmation"):
        return f"{claim} <sub>(human-confirmed)</sub>"
    return claim


def _finding_detail(f):
    lines = []
    lines.append(f"#### {f.get('id')} — {f.get('claim', '')}")
    lines.append("")
    lines.append(f"**File:** {file_link(f)}")
    score = f.get("score_phase4") or f.get("score_phase3")
    strength = f.get("confirmed_strength")
    score_line = f"**Score:** {score}" if score is not None else ""
    if strength:
        score_line = f"{score_line} ({strength})" if score_line else f"**Strength:** {strength}"
    if score_line:
        lines.append(score_line)
    if f.get("reason"):
        lines.append(f"**Reason:** {f['reason']}")
    hc = f.get("human_confirmation")
    if hc:
        pf = hc.get("promoted_from") or {}
        lines.append(
            f"**Human-confirmed:** @{hc.get('reviewer', '?')} at {hc.get('ts', '?')} — {hc.get('reason', '')}"
        )
        pf_disp = pf.get("disposition")
        pf_disp_label = SECTION_LABEL[pf_disp][3] if pf_disp in SECTION_LABEL else "?"
        lines.append(
            f"_Promoted from disposition=`{pf_disp_label}` / "
            f"actionability=`{pf.get('actionability', '?')}` / "
            f"score_phase4={pf.get('score_phase4')}_"
        )
        fix_hint = hc.get("fix_hint")
        if fix_hint:
            lines.append(f"**Fix direction:** {fix_hint}")

    # Auto-recommendation block (auto_fix_hint, more-auto.md). Renders
    # when the field is present AND it adds information the
    # human_confirmation block doesn't already convey — i.e. the finding
    # hasn't been promoted yet, OR the user edited the hint at promotion
    # time so the auto-rec serves as the original-recommendation audit
    # trail. When promoted with the auto-rec hint verbatim, suppress
    # this block to avoid double-display of the same fix_hint.
    afh = f.get("auto_fix_hint")
    hc_fix_hint = (hc or {}).get("fix_hint") if hc else None
    if afh and hc_fix_hint != afh.get("hint"):
        confidence = afh.get("confidence", "?")
        lines.append(f"**Auto-recommendation ({confidence}):** {afh.get('hint', '')}")
        concerns = afh.get("concerns") or []
        if afh.get("second_opinion") == "concerns" and concerns:
            lines.append(f"- _Concerns:_ {'; '.join(concerns)}")
        alternatives = afh.get("alternatives") or []
        if alternatives:
            alt_bits = " · ".join(
                f"**{alt.get('label', '?')}** {alt.get('title', '')}" for alt in alternatives
            )
            lines.append(f"- _Alternatives:_ {alt_bits}")

    vr = f.get("validation_result") or {}
    evidence = vr.get("evidence") or []
    if evidence:
        lines.append("")
        lines.append("**Evidence:**")
        for e in evidence:
            lines.append(f"- {e}")

    fp = vr.get("fix_proposal") or {}
    if fp.get("approach"):
        lines.append("")
        lines.append(f"**Approach:** {fp['approach']}")
    if fp.get("files_to_modify"):
        lines.append("")
        lines.append("**Files to modify:**")
        for entry in fp["files_to_modify"]:
            what = f" — {entry.get('what', '')}" if entry.get("what") else ""
            why = f" (why: {entry['why']})" if entry.get("why") else ""
            lines.append(f"- `{entry.get('file', '?')}`{what}{why}")

    vc = vr.get("verification_context") or {}
    verify = vc.get("how_to_verify_fix") or []
    if verify:
        lines.append("")
        lines.append("**Verification:**")
        for v in verify:
            lines.append(f"- {v}")
    edge = vc.get("edge_cases_to_preserve") or []
    if edge:
        lines.append("")
        lines.append("**Edge cases to preserve:**")
        for e in edge:
            lines.append(f"- {e}")

    # Last fix-attempt summary, if any.
    att = latest_attempt(f)
    if att:
        lines.append("")
        raw = att.get("phase_9_outcome")
        outcome = "fixed and verified" if raw == "verified" else (raw or "(not classified)")
        run_id = att.get("run_id", "?")
        lines.append(f"**Latest fix attempt ({run_id}):** {outcome}")
        if att.get("phase_9_finding"):
            lines.append(f"- Phase 9 finding: {att['phase_9_finding']}")
        rfp = att.get("revised_fix_proposal") or {}
        if rfp.get("approach"):
            lines.append(f"- Revised approach: {rfp['approach']}")

    return "\n".join(lines)


def render_auto_recommendations(buckets):
    """Findings with auto_fix_hint, regardless of disposition or lane.

    Surfaces AI-authored fix recommendations in the rendered MD so reviewers
    see them in the published PR comment without running :fix or
    :walkthrough first. Confirmed_manual / confirmed_report / light-lane
    confirmed_mechanical findings still appear in their disposition sections
    below — this is an overlay view, not a relocation.
    """
    rows = []
    for finding_list in buckets.values():
        for f in finding_list:
            if f.get("auto_fix_hint") and not f.get("human_confirmation"):
                rows.append(f)
    rows.sort(key=lambda f: f.get("id", ""))
    if not rows:
        return ""

    lines = [f"### Auto-recommendations ({len(rows)})", ""]
    lines.append(
        "_AI-authored fix directions for findings that aren't auto-fixable today. "
        "Run `/adamsreview:fix` to batch-apply with one confirmation, or "
        "`/adamsreview:walkthrough` to review one-by-one._"
    )
    lines.append("")
    lines.append("| # | Score | Disp | File | Recommendation |")
    lines.append("|---|-------|------|------|----------------|")
    for f in rows:
        afh = f.get("auto_fix_hint") or {}
        hint = afh.get("hint", "")
        if len(hint) > 140:
            hint = hint[:137] + "..."
        confidence = afh.get("confidence", "?")
        disp_short = SECTION_LABEL.get(f.get("disposition"), ("", "", "", "?"))[3]
        lines.append(
            f"| {f.get('id')} | {f.get('score_phase4') or f.get('score_phase3') or ''} | "
            f"{disp_short} | {file_link(f)} | _{confidence}:_ {hint} |"
        )

    lines.append("")
    lines.append("<details><summary>Full recommendations and alternatives</summary>")
    for detail in (_finding_detail(f) for f in rows):
        lines.append("")
        lines.append(detail)
    lines.append("")
    lines.append("</details>")

    return "\n".join(lines)


def render_deep_other(buckets, disposition):
    rows = [f for f in buckets.get(disposition, []) if f.get("validation_lane") == "deep"]
    if not rows:
        return ""
    _, label, glyph, _short = SECTION_LABEL[disposition]
    lines = [f"### {glyph} {label} ({len(rows)})", ""]
    if disposition == "confirmed_manual":
        lines.append(
            "_Not auto-applied by `/adamsreview:fix` directly — these need a confirmation step. "
            "Findings with an auto-recommendation get batch-confirmed at `:fix`'s Phase 7.5 "
            "preflight (or `:walkthrough` Step 4.5); use `/adamsreview:promote <finding_id>` "
            "for a single-finding manual override._"
        )
        lines.append("")
        lines.append("| # | Score | Impact | File | Issue | Why manual |")
        lines.append("|---|-------|--------|------|-------|-------------|")
        for f in rows:
            why = f.get("reason") or ""
            lines.append(
                f"| {f.get('id')} | {f.get('score_phase4') or ''} | {f.get('impact_type', '?')} | "
                f"{file_link(f)} | {f.get('claim', '')} | {why} |"
            )
    else:  # uncertain, confirmed_report
        lines.append("| # | Score | Impact | File | Issue |")
        lines.append("|---|-------|--------|------|-------|")
        for f in rows:
            lines.append(
                f"| {f.get('id')} | {f.get('score_phase4') or ''} | {f.get('impact_type', '?')} | "
                f"{file_link(f)} | {f.get('claim', '')} |"
            )
    if disposition == "uncertain":
        lines.append("")
        lines.append("Phase 4 couldn't confirm decisively. Re-run `/adamsreview:review` if you suspect this deserves")
        lines.append("further investigation with fresh context.")
    return "\n".join(lines)


def render_light_lane(buckets):
    rows = []
    # `uncertain` included — see render_summary comment. The light-lane table
    # already carries a Disposition column, so mixed dispositions fit the
    # existing shape; no section split needed (deep lane uses render_deep_other
    # for Uncertain, but the light lane's single-table design accommodates all
    # confirmed/uncertain dispositions in one rendering pass).
    # `partial` / `regression` / `resolved` included for lane symmetry with
    # the deep-lane fix-attempt path: light-lane findings promoted via :promote
    # and then fixed by :fix can land in any of these states, and would
    # otherwise be absent from the rendered table while still counted in the
    # headline (silent-drop class).
    for disp in ("confirmed_mechanical", "partial", "regression", "resolved",
                 "confirmed_manual", "confirmed_report", "uncertain"):
        for f in buckets.get(disp, []):
            if f.get("validation_lane") == "light":
                rows.append(f)
    if not rows:
        return ""
    lines = ["## Light lane — ux, policy, architecture", ""]
    if any(f.get("disposition") in ("confirmed_mechanical", "confirmed_manual") for f in rows):
        lines.append(
            "_Light-lane findings — including rows labeled auto-fixable — aren't applied by "
            "`/adamsreview:fix` directly. Findings with an auto-recommendation get "
            "batch-confirmed at `:fix`'s Phase 7.5 preflight (or `:walkthrough` Step 4.5); "
            "use `/adamsreview:promote <finding_id>` for a single-finding manual override._"
        )
        lines.append("")
    lines.append("| # | Score | Impact | File | Finding | Disposition |")
    lines.append("|---|-------|--------|------|---------|-------------|")
    for f in rows:
        lines.append(
            f"| {f.get('id')} | {f.get('score_phase4') or ''} | {f.get('impact_type', '?')} | "
            f"{file_link(f)} | {_claim_with_promotion(f)} | {SECTION_LABEL[f['disposition']][3]} |"
        )

    promoted_rows = [f for f in rows if f.get("human_confirmation")]
    if promoted_rows:
        lines.append("")
        lines.append("<details><summary>Promoted findings — details</summary>")
        for f in promoted_rows:
            lines.append("")
            lines.append(_finding_detail(f))
        lines.append("")
        lines.append("</details>")

    return "\n".join(lines)


def render_polish_clusters(buckets):
    """Surface clustered below_gate findings in a dedicated section.

    Phase 3 parks nits under `below_gate` so they don't flood the report,
    and the existing section renderers drop them entirely. But a dense
    run of nits in one area is its own signal — ultrareview-style "nit"
    lists exist for exactly this case. Cluster detection is shared with
    `render_summary` via `_clustered_below_gate` so the summary's
    "Filtered out" bullet can split below_gate counts between findings
    that show up here vs. those that stay fully filtered.
    """
    clustered_by_file = _clustered_below_gate(buckets)
    if not clustered_by_file:
        return ""

    def loc_cell(f):
        lr = f.get("line_range") or []
        if len(lr) == 2 and lr[0] == lr[1]:
            return f"L{lr[0]}"
        if len(lr) == 2:
            return f"L{lr[0]}-{lr[1]}"
        return ""

    total = sum(len(v) for v in clustered_by_file.values())
    lines = [f"## Polish — below threshold, clustered ({total})", ""]
    lines.append(
        "Below-gate findings (score < 45) that cluster in the same area — "
        "not worth surfacing individually, but dense enough that a human pass "
        "may catch something the pipeline filtered out."
    )
    lines.append("")
    lines.append("| # | Score | File | Rough location | Concern |")
    lines.append("|---|-------|------|----------------|---------|")
    for file_path in sorted(clustered_by_file.keys()):
        for f in clustered_by_file[file_path]:
            # Explicit null-check rather than `or`: score_phase3 == 0 is a
            # real below_gate value (ray-finance case study) and would
            # render blank under truthiness fallback.
            score = f.get("score_phase3")
            score_cell = str(score) if score is not None else ""
            lines.append(
                f"| {f.get('id', '?')} | {score_cell} | `{file_path}` | "
                f"{loc_cell(f)} | {f.get('claim', '')} |"
            )
    return "\n".join(lines)


def render_pre_existing(buckets):
    rows = buckets.get("pre_existing_report", [])
    if not rows:
        return ""
    lines = [f"## Pre-existing — report-only ({len(rows)})", ""]
    lines.append("Shown only when `origin_confidence: high`. Never auto-fixed in v1 (§13.1 pre-existing override).")
    lines.append("")
    lines.append("| # | Score | File | Finding | Follow-up |")
    lines.append("|---|-------|------|---------|-----------|")
    for f in rows:
        followup = f.get("suggested_follow_up") or ""
        lines.append(
            f"| {f.get('id')} | {f.get('score_phase4') or ''} | {file_link(f)} | "
            f"{f.get('claim', '')} | {followup} |"
        )
    return "\n".join(lines)


_OUTCOME_LABEL = {
    "verified":    "✓ fixed and verified",
    "partial":     "⚠ partial",
    "regression":  "✗ regression (reverted)",
    # phase_9_outcome=null is the overlap-abort case (§4 Phase 9.pre):
    # the run aborted before Phase 9 could classify the finding, but the
    # audit trail still records the attempt. Label distinctly so the
    # reader can tell it apart from a legit classification.
    None:          "⚠ overlap-abort",
}


def _outcome_label(att):
    outcome = att.get("phase_9_outcome")
    return _OUTCOME_LABEL.get(outcome, str(outcome))


def render_fix_runs(artifact):
    """Derive per-run summary + per-finding table by grouping fix_attempts by run_id.

    DESIGN §7: "A `## Fix runs` section is appended showing each run's
    summary." Each run produces a header line (run_id, timestamp,
    committed SHAs, outcome counts) and a table of per-finding outcomes.
    Runs are ordered oldest-first so the section flows chronologically
    top-to-bottom, matching how GitHub renders the enclosing PR comment.
    """
    runs = defaultdict(list)  # run_id -> list of (finding_id, attempt)
    for f in artifact.get("findings", []):
        for att in f.get("fix_attempts") or []:
            runs[att.get("run_id")].append((f.get("id"), att))
    if not runs:
        return ""

    # Use the min timestamp within the run as its stable anchor (attempts
    # within a run should share a timestamp but don't strictly have to —
    # the overlap-abort batch does share one, the committed branch might
    # ts-stamp all findings at 9d within the same second, but ordering
    # is driven by the earliest attempt-ts).
    def run_ts(entries):
        tss = [att.get("timestamp") or "" for _, att in entries]
        return min(tss) if tss else ""

    lines = ["## Fix runs", ""]
    for run_id, entries in sorted(runs.items(), key=lambda kv: run_ts(kv[1])):
        ts = run_ts(entries)
        outcomes = defaultdict(int)
        shas = set()
        for _, att in entries:
            outcomes[att.get("phase_9_outcome")] += 1
            if att.get("output_sha"):
                shas.add(att["output_sha"][:7])
        sha_list = ", ".join(f"`{s}`" for s in sorted(shas)) if shas else "(no commit)"

        # Human-readable outcome summary ordered by the label precedence
        # we want to emphasize first: verified → partial → regression → overlap.
        summary_parts = []
        for key, label in (("verified", "fixed and verified"),
                           ("partial", "partial"),
                           ("regression", "regression"),
                           (None, "overlap-abort")):
            if outcomes.get(key):
                summary_parts.append(f"{outcomes[key]} {label}")

        lines.append(f"### Run `{run_id}` — {ts}")
        lines.append("")
        lines.append(f"- Outcomes: {', '.join(summary_parts) if summary_parts else '(none)'}")
        lines.append(f"- Commits: {sha_list}")
        lines.append("")
        lines.append("| Finding | Group | Outcome | phase_9_finding |")
        lines.append("|---------|-------|---------|-----------------|")
        # Sort per-finding rows by finding id for stable table order.
        for fid, att in sorted(entries, key=lambda p: p[0] or ""):
            pf = att.get("phase_9_finding") or ""
            lines.append(
                f"| {fid} | {att.get('fix_group_id', '?')} | "
                f"{_outcome_label(att)} | {pf} |"
            )
        lines.append("")

    # Trim the trailing empty line so the section ends cleanly (the join
    # between sections adds its own).
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines)


def render_footer(artifact):
    return "🤖 Generated with the [adamsreview](https://github.com/adamjgmiller/adamsreview) Claude Code Review Plugin"


# ----- Assembly ---------------------------------------------------------

def render(artifact):
    buckets = findings_by_disposition(artifact)
    cross_cutting = artifact.get("cross_cutting_groups") or []

    sections = [
        MARKER,
        render_header(artifact),
        render_summary(buckets),
        "---",
        "## Deep lane — correctness & security" if any(
            f.get("validation_lane") == "deep" for f in artifact.get("findings", [])
        ) else "",
        render_deep_auto(buckets, cross_cutting),
        render_auto_recommendations(buckets),
        render_deep_other(buckets, "confirmed_manual"),
        render_deep_other(buckets, "uncertain"),
        render_deep_other(buckets, "confirmed_report"),
        render_light_lane(buckets),
        render_polish_clusters(buckets),
        render_pre_existing(buckets),
        render_fix_runs(artifact),
        "---",
        render_footer(artifact),
    ]
    # Collapse empty sections; separate non-empty ones with a blank line.
    return "\n\n".join(s for s in sections if s) + "\n"


# ----- CLI --------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(
        prog="artifact-render.py",
        description="Render artifact.json -> artifact.md per DESIGN §7."
    )
    p.add_argument("--input", required=True, help="path to artifact.json")
    p.add_argument("--output", help="path to artifact.md (stdout if omitted)")
    args = p.parse_args()

    try:
        artifact = c.read_json(args.input)
    except FileNotFoundError:
        c.err_prompt(
            f"artifact not found at {args.input}",
            action="run artifact-patch.py --init first."
        )
        return c.EXIT_VALIDATION

    errors = c.validate(artifact)
    if errors:
        shown = errors[:10]
        overflow = [f"  (+{len(errors) - 10} more)"] if len(errors) > 10 else []
        c.err_prompt(
            f"input artifact is invalid ({len(errors)} schema violation(s))",
            context=["  " + e for e in shown] + overflow,
            action="fix the artifact, or re-run artifact-patch.py to regenerate."
        )
        return c.EXIT_VALIDATION

    md = render(artifact)
    if args.output:
        Path(args.output).write_text(md)
        print(f"wrote {args.output}")
    else:
        sys.stdout.write(md)
    return c.EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
