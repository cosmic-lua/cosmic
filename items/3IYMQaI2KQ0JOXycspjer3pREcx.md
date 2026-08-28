## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **generic T** class, 8 sites. Files:
`cosmic/fetch/extras.tl` 4; `cosmic/deep.tl` 2; `cosmic/fs/walk.tl` 1;
`cosmic/shape.tl` 1. The shape is a fresh table, a map view, or a value
pulled out of a dynamic walk, re-typed as a generic parameter, because
Teal cannot relate the concrete thing the body built to the `T` the
signature promised: `deep.copy<T>` returns `copy_impl(value, {}) as T`,
`shape.check<T>` returns `holder[1] as T` after its walk has verified
every field the spec names, and `fetch.prepare<T>` shuttles a `T`
through a mirror record and a shallow copy. The census verdict is **why
it is a floor**, and uniquely among the five floor classes it does not
compress: the body of a generic function cannot construct a value of
its own type parameter, only the caller knows what `T` is, and the walk
underneath is dynamic by design — so the assertion the cast makes IS
the function's contract, stated at the one place it is made. Eight
sites, one per generic body that returns a constructed value, already
one per function. This item's work is therefore to PROVE that floor or
lower it, not to assume it: read all eight, check whether
`cosmic/fetch/extras.tl`'s four collapse (the mirror record and the
copied map are three casts around one shallow copy, which may want one
helper rather than four assertions), and record the verified count. If
the floor holds at eight, the deliverable is the confirmation and no
`_build/casts_baseline.tl` change; if any collapse, the diff lowers the
affected rows. Either outcome feeds the G3 wording decision, whose
current floor arithmetic assumes eight here. The class description and
exemplar citation are the `### generic T` section of
`docs/design/casts.md`; the per-site list is
`docs/design/cast-sites.tsv`.
