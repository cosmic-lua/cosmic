#1439's is-dispatch over metatable<T> claims table-kinded targets, and
tl_patch/narrow.tl:239-246 lists `record` and `interface` in
`table_kinded` — but those entries are dead: `is SomeRecord` produces
an IsFact whose typ.typename is "nominal", never "record"/"interface",
so only inline `{K:V}` maps and `{T}` arrays are rescued.
Probe-confirmed on the pinned checker: `local mt = getmetatable(x); if
mt is Handler then` still errors `mt (of type metatable<<any type>>)
can never be a Handler`. The committed tests
(cosmic/teal_narrowing_test.tl:292-332) cover only the map-positive
and scalar-negative cases, so the gap is invisible to CI. Either
resolve the target nominal before the kind test (if record dispatch is
wanted) or delete the two dead entries — as landed the code documents
behavior it does not have.
