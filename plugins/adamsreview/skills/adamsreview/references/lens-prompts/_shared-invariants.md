Read the diff between `$comparison_ref` and HEAD.

Return a JSON array of candidates. Each candidate:

```
{
  "file": "src/path/to/file.ts",
  "line_range": [start, end],
  "claim": "one-sentence description of the issue",
  "evidence_snippet": "the exact code lines implicated",
  "impact_type": "correctness" | "security" | "ux" | "policy" | "architecture",
  "origin": "introduced_by_pr" | "pre_existing" | "unknown",
  "origin_confidence": "high" | "medium" | "low",
  "source_family": "<set by lens; see lens-specific guidance>"
}
```

Each lens's section below specifies the `impact_type` and
`source_family` values to use. Other fields follow the shapes above.

`line_range` must be file-absolute. `line_range[0]` and `line_range[1]`
refer to actual line numbers in the reviewed file at `$reviewed_sha`,
counted from 1. Required: `line_range[0]` >= 1 and `line_range[1]` <=
the file's total line count. Do not copy the numbers inside unified-
diff hunk headers (`@@ -a,b +c,d @@`) — those describe hunk positions,
not where a finding lives. To cite a line, read the `+`-prefixed lines
in the hunk and count forward from the hunk's post-image start; do
not reuse `a` or `c` verbatim.

Default `origin: "introduced_by_pr"`, `origin_confidence: "high"`. Set
`origin: "pre_existing"` only when BOTH (1) the implicated code is
unchanged by this diff AND (2) the bug exists independently of this
PR — reverting this PR would not close the finding. If pre-existing-
looking code became wrong because of new code this PR adds elsewhere
(a stale diagram now contradicted by a new pipeline step; a function
missing a field a new caller needs; a doc bullet contradicted by a
new fallback path), keep `origin: "introduced_by_pr"` — the PR is
causally responsible, even though the cited lines are old.
