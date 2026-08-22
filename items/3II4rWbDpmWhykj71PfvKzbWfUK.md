`cmd_new` declares a parameter `string` that every internal caller
passes `nil` for, and two of the three graph verbs carry no doc
comment at all.

## Evidence

Noticed 2026-08-22 by the agent moving these verbs into
`_work/gitgraph.tl` (whilp/cosmic#1327), which was forbidden from
fixing anything inside a pure move. Both predate the split and rode
across unchanged.

**The type does not admit the nil it routinely receives.** `cmd_new`'s
`spec` parameter is declared `string`. `_work/fixture.tl`'s
`file_item` passes `nil` in that slot, and so does every moved test
that calls the verb directly:

    graph.cmd_new(s, title, parent, nil, "", force, ...)

Only `_work/gitboard.tl` ever passes a body. This is the inverse of
the repo's own honest-nil rule — the type must admit absence — and it
is the kind of quiet mismatch the checker would otherwise catch.

Adjacent, in the same constructor: `repo = repo or ""` defends
against a nil `repo: string`, while `title` and `parent` — same
declared type, same exposure — do not. One table literal, two
policies.

**No doc comments.** `cmd_block` carries a full `---` block with
`@param`/`@return` tags. Its two neighbours in the new module,
`cmd_new` and `cmd_attach`, have none — no summary, no tags — despite
being the two verbs with the most parameters (`cmd_new` takes seven).
House style calls for `---` with `@param`/`@return`; nothing enforces
it, which is why this survived.

## Why it might matter

The seven-parameter verb with no documentation and a lying signature
is the one every session calls to file a capture, and the one a
refinement pass reaches for most. A wrong argument in slot four is
currently a silent nil rather than a type error.

## Directions, not a decision

- Declare `spec?: string` (or `string | nil`) to match what callers
  pass, and make the nil-defence in the constructor consistent across
  `title`, `parent` and `repo`.
- Add the two missing doc blocks, matching `cmd_block`'s shape.
- Consider whether the doc-comment convention is worth a lint: it is
  house style that nothing checks, which is how two verbs lost theirs.

## Where the evidence is

`_work/gitgraph.tl` after whilp/cosmic#1327, `_work/fixture.tl`'s
`file_item`, and the `cmd_new` call sites in `_work/gitgraph_test.tl`.
