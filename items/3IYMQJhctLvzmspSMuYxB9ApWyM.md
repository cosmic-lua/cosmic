## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **module surface record** class, 8 sites.
Files: `_types/gentype.tl` 3; `_types/tlast.tl` 2;
`cosmic/coverage/init.tl` 2; `_types/tlast_test.tl` 1. The shape is a
`require` result, or a freshly loaded chunk, re-typed to a hand-written
record naming only the part the caller uses —
`require("_types.gentype_render") as GentypeRender` is the clean form,
with the record declared immediately above the require. The record is a
deliberate narrowing rather than a workaround: it documents the seam
and keeps a large module's whole surface out of the importer's type.
But it is spelled as a cast, and the cast is on the wrong side of the
seam. The census verdict is **what closes it here**: these are this
tree's own modules, so declaring the returned record in the module's
OWN source and returning it typed makes a plain `require` resolve to
that type — which is what every other `cosmic.*` import already does
through the cosmic searcher. Moving the three `_types/gentype_*`
records into their own modules is the bulk of it. The two
`cosmic/coverage/init.tl` sites and the `_types/tlast*` chunk loads are
the harder half: they load a module through an indirection deliberately
(bypassing static resolution, or loading a second fresh copy of tl), so
the record stays hand-written and the honest question is whether it can
live beside the loader rather than at each call. The closure diff
lowers the affected `_build/casts_baseline.tl` rows. The class
description and exemplar citation are the `### module surface record`
section of `docs/design/casts.md`; the per-site list is
`docs/design/cast-sites.tsv`.
