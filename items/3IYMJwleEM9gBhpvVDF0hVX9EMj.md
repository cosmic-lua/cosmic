## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **userdata boundary** class, 22 sites.
Files: `cosmic/fs/types.tl` 12; `cosmic/fs/find.tl` 3;
`cosmic/fs/ops.tl` 2; `cosmic/fs/walk.tl` 2; `cosmic/embed/init.tl` 1;
`cosmic/fs/tree.tl` 1; `cosmic/zip.tl` 1. The shape is a raw userdata
handle from a binding re-typed to the record that describes it, or a
method table typed `{string: any}` whose `self` is `any` and is
re-typed once per method. The census verdict is **why it is a floor**:
a userdata value has no structure Teal can read, so the record
describing it is an assertion by construction and the assertion has to
be written somewhere — but the floor is one cast per handle TYPE at its
wrap point, not one per use. Six handle types exist today (`Stat`,
`Statfs`, the two directory handles, the embed handle, the zip reader),
so 22 sites sit over a floor of six, and the gap is almost entirely
`cosmic/fs/types.tl`: nine of its twelve are `(self as unix.Statfs):`
method bodies that exist only because the method table is typed
`{string: any}`. Declaring that table's `self` closes all nine at once
and is the bulk of the work; the remaining call-site casts in `find`,
`walk`, `ops` and `tree` collapse once each wrap function returns the
handle already typed. The closure diff lowers the affected
`_build/casts_baseline.tl` rows, and a residual six is the expected
end state rather than a failure. The class description and exemplar
citations are the `### userdata boundary` section of
`docs/design/casts.md`; the per-site list is
`docs/design/cast-sites.tsv`.
