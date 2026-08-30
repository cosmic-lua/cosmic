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

## Rework (2026-08-30, request changes on PR #1538)

Live measurement by the reviewer (last 30 PR bodies on this repo):
28/30 carry `&#39;` and/or `&#34;` from ordinary prose possessives, so
an any-artifact blocking refusal refuses ~93% of correct handovers —
including PR #1538's own body — and the named entity `&quot;` appears
in zero live bodies (the transport emits numeric `&#34;`). The
detection narrows: fire only when an artifact appears INSIDE a code
span (between backticks or inside a fenced ``` block) — the one place
sanitization corrupts the meaning a reviewer relies on — and match
numeric `&#34;` (keep `&#39;`; the named forms may ride alongside but
are not the live signal). Blocking severity then stands, matching the
existing single-channel shape. Tests: a prose-apostrophe artifact
outside any code span passes clean; `&#39;` inside a backtick span
blocks; `&#34;` inside a fenced block blocks; mutation-verify the
span-scoping (widen the check back to whole-body, watch the
prose-passes-clean test go red).

## Resolution (2026-08-30) — rejected, not-planned

Operator decision after two review rounds. What was learned: the
transit sanitizer's harmful half (tag-shaped text DELETED) leaves no
artifact and is undetectable from the body side; the detectable half
(entity-escaped quotes) is lossless in rendered prose and corrupts
only code spans — a cosmetic case on a field the doctrine already
demotes (PR bodies carry no evidence). Scoping detection to code
spans required a markdown span parser inside board machinery, which
produced a real phantom-span bug on its first cut; the maintenance
surface exceeds the value of guarding a non-load-bearing field
against its recoverable failure mode. PR #1538 closed unmerged; the
branch retains the working span-scoped implementation if this is ever
revisited.
