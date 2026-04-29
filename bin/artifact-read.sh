#!/usr/bin/env bash
# artifact-read.sh — safe reader for artifact.json (DESIGN §8.1, §21.1).
#
# Thin wrapper around jq. Three read modes (mutually exclusive):
#   --filter '<jq expr>'   apply any jq expression; stdout is the result
#   --finding-id <id>      single-finding lookup
#   --summary              canned counts per current_state / disposition /
#                          impact_type / validation_lane
#
# Default artifact path resolution via ~/.adams-reviews/<slug>/<branch>/
# latest.txt is deferred to Stage 2 (Phase 0 computes the slug); Stage 1
# callers pass --path explicitly.
#
# Exits:
#   0   success
#   1   artifact not found, unreadable, or jq error
#   64  usage error (no mode, multiple modes, unknown flag)

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --path <artifact.json> (--filter '<jq>' | --finding-id <id> | --summary)

Modes (exactly one):
  --filter '<jq>'      apply a jq expression to the artifact
  --finding-id <F001>  look up a single finding by id
  --summary            print counts by current_state, disposition,
                       impact_type, validation_lane
USAGE
}

die_usage() {
    echo "ERROR: $1" >&2
    usage
    exit 64
}

ARTIFACT=""
MODE=""
FILTER=""
FID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            [[ -n "${2:-}" ]] || die_usage "--path requires a value"
            ARTIFACT="$2"; shift 2 ;;
        --filter)
            [[ -z "$MODE" ]] || die_usage "specify only one of --filter, --finding-id, --summary"
            [[ -n "${2:-}" ]] || die_usage "--filter requires a jq expression"
            MODE="filter"; FILTER="$2"; shift 2 ;;
        --finding-id)
            [[ -z "$MODE" ]] || die_usage "specify only one of --filter, --finding-id, --summary"
            [[ -n "${2:-}" ]] || die_usage "--finding-id requires a value"
            MODE="finding"; FID="$2"; shift 2 ;;
        --summary)
            [[ -z "$MODE" ]] || die_usage "specify only one of --filter, --finding-id, --summary"
            MODE="summary"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$ARTIFACT" ]] || die_usage "--path is required"
[[ -n "$MODE" ]] || die_usage "specify one of --filter, --finding-id, --summary"

if [[ ! -f "$ARTIFACT" ]]; then
    echo "ERROR: artifact not found at $ARTIFACT" >&2
    echo "Action: check the path, or run artifact-patch.py --init first." >&2
    exit 1
fi

case "$MODE" in
    filter)
        # Let jq's own error-as-prompt surface verbatim; prefix for clarity.
        if ! jq "$FILTER" "$ARTIFACT" 2> >(sed 's/^jq: /ERROR (jq): /' >&2); then
            echo "Filter was: $FILTER" >&2
            exit 1
        fi
        ;;

    finding)
        result=$(jq --arg fid "$FID" '.findings[] | select(.id == $fid)' "$ARTIFACT")
        if [[ -z "$result" ]]; then
            existing=$(jq -r '[.findings[].id] | join(", ")' "$ARTIFACT")
            echo "ERROR: no finding with id '$FID'" >&2
            echo "Valid values: ${existing:-(no findings in this artifact)}" >&2
            echo "Action: check --finding-id, or list ids with --filter '[.findings[].id]'." >&2
            exit 1
        fi
        # printf, not echo — `echo "$x"` in zsh / `/bin/sh` / bash with
        # xpg_echo collapses `\\` to `\`, mangling JSON-encoded backslashes
        # (e.g., a finding evidence string containing `\d`) so the next jq
        # in a downstream pipe parse-errors. printf '%s' is shell-portable.
        printf '%s\n' "$result"
        ;;

    summary)
        # Counts per routing key. disposition is the primary (§5.2.1);
        # current_state, impact_type, validation_lane for at-a-glance.
        # Key names match DESIGN §12.1 so phases.jsonl aggregators and
        # the --summary consumer read the same shape.
        jq '{
            findings_total: (.findings | length),
            counts_by_state:        (.findings | group_by(.current_state) | map({key: (.[0].current_state // "null"), value: length}) | from_entries),
            counts_by_disposition:  (.findings | group_by(.disposition)   | map({key: (.[0].disposition   // "null"), value: length}) | from_entries),
            counts_by_impact_type:  (.findings | group_by(.impact_type)   | map({key: (.[0].impact_type   // "null"), value: length}) | from_entries),
            counts_by_validation_lane: (.findings | group_by(.validation_lane) | map({key: (.[0].validation_lane // "null"), value: length}) | from_entries)
        }' "$ARTIFACT"
        ;;
esac
