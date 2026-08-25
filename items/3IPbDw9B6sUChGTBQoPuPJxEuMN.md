## Goal

G3 — an honest type layer, no escape hatches. The design documents
this outcome decomposes through (`docs/design/casts.md`,
`docs/design/nil-flow.md`) carry their whole value in quoted
`file:line` citations: the measuring prototype is thrown away by
construction, so a reader's only check on a class count is the two or
three sites the document quotes. Nothing verifies that a quoted line
is the line that is actually there.

## Evidence

Filed from the review of 3IOXhlWb (`docs/design/nil-flow.md`, PR
#1375), where reading the cited sites against the tree at the PR's own
head (`faf54789`) found three defects in six examples:

1. The document quotes

   ```text
   -- cosmic/fetch/verbs_test.tl:78
   local res = fetch.head(base .. "/x", {allow_private = true})
   ```

   Line 78 of that file is `return fetch.get(base .. "/x",
   {allow_private = true})`, and `grep -n 'fetch.head'
   cosmic/fetch/verbs_test.tl` reports nothing — the quoted line is in
   neither that position nor that file. It is the sole example for one
   of the two mechanisms in a 45-site class.

2. The `_build/size.tl:160` example quotes a block that begins at
   `:158` (`return string.format(`) and whose flagged expression is at
   `:162` (`cbin, cbin - pbin,`); `:160` is `clines, clines - plines,`.

3. `AGENTS.md:180-184` is cited for text that begins at `:181`; `:180`
   is the record-FIELDS sentence the same section separately cites as
   `179-180`. The overlap is what makes the document's "48 lines of
   prose retired" arithmetic one line high.

None of these is catchable by any gate the repo runs today: `--make
ci` passed on that head, five CI lanes green.

The genre is growing, not one-off, and it already has two distinct
citation shapes — measured against `faf54789`:

- **Fenced-block header comment**, `-- <path>:<line>` as a block's
  first line, followed by the quoted source. 8 of them, all in
  `docs/design/nil-flow.md`
  (`grep -rnE '^-- [A-Za-z_/.]+\.tl:[0-9]+' docs/`). All three defects
  above are in this shape.
- **Inline backticked reference**, `` `cosmic/json.tl:135` `` in
  running prose, with the claim about that line stated around it. 13
  of them in `docs/design/casts.md`
  (`grep -coE '\.tl:[0-9]+' docs/design/casts.md`), 0 in that file of
  the fenced shape — so the inline form is the majority today and the
  one a check that only reads fenced blocks would miss entirely.

Every one of the five nil-flow follow-ups (3IPXM4K2, 3IPXQ1Zw,
3IPXQcgW, 3IPXQuYu, 3IPXRRd2) plus the six casts slices carries its
parent document's numbers and sites into its own spec.

## Proposed change

A pure lint check registered in the existing `cosmic --check lint`
pass (alongside `fallible-returns`, `find-needle`, cast
justification), covering both shapes at the strength each admits:

- **Both shapes — the citation resolves.** `<path>` is a tracked file
  and `<line>` is within it. A renamed file or a line past
  end-of-file is a failure naming the document, the citation, and
  what is actually there. This is the whole check for the inline
  form, and it is worth having alone: it is what a landed slice moving
  code out from under a citation breaks first.
- **Fenced shape — the quote matches.** The block's next non-empty
  line must match the source at `<line>`, ignoring leading
  indentation and any trailing `-- flagged: ...` annotation the
  document adds. Defect 1 above is exactly this check failing.

Open questions for refinement, in rough order of weight:

- Which markdown trees the check walks (`docs/**` only, or every
  tracked `.md`), and whether a document opts in.
- Whether a multi-line quote must match every line or only its first
  — the nil-flow examples quote 2-6 lines with elisions.
- Whether prose line RANGES (`AGENTS.md:180-184`) are in scope.
  Defect 3 is one, and resolution alone would not have caught it — a
  range whose start is one line early still resolves. Doing better
  means the document asserting what the range contains, which is a
  different and larger design.
- Where the check lives: `_tool/`'s pure lint checks, with the
  registration the other checks use.

## Non-goals

- Not the markdown cross-reference lint (3IKEcDqs): that resolves
  stable IDs and links BETWEEN documents and is blocked on
  `cosmic.markdown` (3IKD33rv). This one reads a source file at a
  numbered line and needs no markdown AST — it can land first and
  independently.
- Not a fix to any document's existing citations. Those are the
  reviewed slice's rework, and this lint must not land inside the PR
  it polices.
