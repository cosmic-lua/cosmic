## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **numeric narrowing** class, 9 sites.
Files: `cosmic/format/init.tl` 4; `cosmic/_literal_lex.tl` 3;
`cosmic/fs/octal.tl` 1; `cosmic/url.tl` 1. The shape is a value the
code has established is an integer but tl declares `number`: digits
just parsed by `tonumber` with an explicit base (`tonumber(digits, 8)`
in the octal parser, `tonumber(hex, 16)` in the URL unescaper and the
literal lexer), a codepoint computation bounded above and below, a
value a `math.type` check has already sorted, and the tl error record's
line and column fields. The census verdict is **what closes it
upstream**: `math.type(x) == "integer"` is a guard the checker could
narrow on, exactly as the carried patch already narrows a nil union on
`== nil`; and `tonumber(s, base)` over a string of digits in that base
is integral by Lua's own contract, so tl could declare the two-argument
form as returning `integer | nil`. Both are checker rules rather than
anything this tree can declare at the call site, so they land in
`3p/tl/tl_patch/` or upstream in tl and stage behind a release and a
`bin/cosmic.pin` bump under the cold-build rule. The four
`cosmic/format/init.tl` sites are line-and-column reads off tl's own
error record and close with whichever of the two rules lands first, or
with the tl-surface work if that arrives sooner. Deleting the casts
lowers the affected `_build/casts_baseline.tl` rows. The class
description and exemplar citation are the `### numeric narrowing`
section of `docs/design/casts.md`; the per-site list is
`docs/design/cast-sites.tsv`.
