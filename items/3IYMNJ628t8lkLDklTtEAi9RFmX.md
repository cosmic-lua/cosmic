## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **metatable access** class, 10 sites.
Files: `cosmic/sqlite/close_test.tl` 4; `_types/tlast.tl` 2;
`cosmic/fs/find_close_test.tl` 2; `cosmic/sqlite/bind.tl` 2. Two forms:
an identity compare against a known metatable (`getmetatable(v) ==
blob_mt as any`, and tl's type-metatable compares in `_types/tlast.tl`),
and a read of a metamethod off a metatable, which is what the two
`__close` tests do to prove the to-be-closed variable really runs its
finalizer. The census verdict is **why it is a floor**: `getmetatable`
and `debug.getmetatable` return `any` by definition — a metatable is a
table whose type is whatever its owner made it, so Lua's own contract
promises a value of no particular type, and a typed wrapper would be
asserting the same thing one level down rather than proving anything.
The class compresses to two and no further: one identity-compare helper
taking a value and a metatable and answering a boolean, and one
metamethod-fetch helper taking a value and a metamethod name and
returning the function or nil. Both belong wherever the tests and
`sqlite/bind.tl` can share them without `cosmic/**` gaining a public
name it does not want; the strip floor makes that a placement question
to settle before the diff. Reducing 10 to 2 lowers the affected
`_build/casts_baseline.tl` rows, and the residual two is the expected
end state. The class description and its two exemplar citations are the
`### metatable access` section of `docs/design/casts.md`; the per-site
list is `docs/design/cast-sites.tsv`.
