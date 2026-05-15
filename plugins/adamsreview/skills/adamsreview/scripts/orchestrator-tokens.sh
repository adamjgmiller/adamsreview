#!/usr/bin/env bash
# orchestrator-tokens.sh — Codex-safe placeholder.
#
# The previous implementation read another runtime's transcript JSONL files.
# The Codex plugin does not have a stable local transcript contract to parse yet, so this
# helper intentionally records a skipped tally and exits successfully. Sub-agent
# token accounting still flows through log-tokens.sh and tally-subagent-tokens.sh.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --artifact <artifact.json> --review-dir <dir> [--since <iso>] [--cwd <path>]

Codex orchestrator transcript tally is not implemented; this helper exits 0
after logging a skipped tally when --review-dir is provided.
USAGE
}

REVIEW_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifact|--since|--cwd)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            shift 2 ;;
        --review-dir)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            REVIEW_DIR="${2:-}"
            shift 2 ;;
        -h|--help)
            usage
            exit 0 ;;
        *)
            echo "ERROR: unknown arg '$1'" >&2
            usage
            exit 64 ;;
    esac
done

if [[ -n "$REVIEW_DIR" && -d "$REVIEW_DIR" ]]; then
    printf 'orchestrator-tally: skipped reason=codex_transcript_contract_unavailable\n' >> "$REVIEW_DIR/trace.md"
fi

echo "orchestrator-tally: skipped"
exit 0
