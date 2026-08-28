## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **container variance** class, 9 sites.
Files: `cosmic/_literal_format.tl` 2; `cosmic/sqlite/bind.tl` 2;
`cmd/cosmic/main.tl` 1; `cosmic/quicksand/proxy.tl` 1;
`cosmic/quicksand/proxy/rules_test.tl` 1; `cosmic/rand_test.tl` 1;
`cosmic/sandbox/init_test.tl` 1. The shape is a container re-typed to
another container type Teal will not relate: an array read as a map or
the reverse, a map widened at its key or its value type, an element
enum used where the element is `string` (`pledge.PROMISES as {string}`),
a bare `table` narrowed to a concrete shape. Teal's containers are
invariant, so even a widening that loses no information needs a cast.
The census verdict is **what closes it upstream**: covariance on READS
is the missing tl rule, and `{Promise}` where `{string}` is wanted, or
`{string: Rule}` where `{string: any}` is wanted, are sound in every
position this tree uses them — the values are only read through the
widened view. That is a subtype relation in the checker, so it lands as
a carried-patch entry (`3p/tl/tl_patch/`) or upstream in tl, and stages
behind a release and pin bump under the cold-build rule. The two
`cosmic/sqlite/bind.tl` sites are the explicit exception: `Params` is
declared `table`, and probing a bare `table` for an array part wants a
declared union rather than a variance rule, so they close here and
separately. Deleting the casts lowers the affected
`_build/casts_baseline.tl` rows. The class description and exemplar
citation are the `### container variance` section of
`docs/design/casts.md`; the per-site list is
`docs/design/cast-sites.tsv`.
