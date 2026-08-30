## Change

PR bodies authored with tag-shaped text arrive HTML-sanitized through
the MCP transport: tags deleted, quotes entity-escaped, inside code
blocks too (evidence: board commit b855dc66; live example: PR #1533/#1534
bodies render `&#39;` for apostrophes). Detection, not prevention.
Measured 2026-08-30: `review.blocks_check` lives at `_work/review.tl:49`
and is invoked from `_work/gitgate.tl:264`. The change:
`review.blocks_check` gains one check — when the PR body contains the
entity-escape artifacts `&#39;` or `&quot;` (substring `find` with
`, 1, true`), it reports the body as transit-sanitized, so a reviewer
knows quoted commands/text in that body are unreliable. Judge whether
the report is a blocking problem or an advisory line by how
blocks_check's existing findings are consumed — follow the existing
shape, do not invent a new severity channel. Fixture-body tests in the
existing review test seam; mutation-verify the detection.

## Non-goals

No transport fix (the sanitizer is upstream). No SKILL.md authoring
rule (PR bodies carry no evidence by doctrine already). No entity
decoding/rewriting of bodies.
