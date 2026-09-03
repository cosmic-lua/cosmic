## Change

`cosmic.sqlite`'s ergonomic layer for the BLOB/TEXT distinction
decided on board item `3IlL8oOGolatj0YHGHWsYEp31Y1` and built in
`3If5s4hNeSCYCYLbOoyuYH1dq7T` (cosmic-lua/cosmopolitan): once that
repo's pin carries the new `value_type(n)`/`column_type(n)`
accessors, `cosmic.sqlite` gets the distinct type those accessors
make possible.

- Define a `cosmic.sqlite.Blob` wrapper record carrying the raw
  bytes.
- `cosmic/sqlite/column.tl`: on a column read, check the new
  `column_type(n)` accessor; wrap the value in `Blob` when the
  runtime type is `SQLITE_BLOB`, leave it a plain string otherwise
  (matching every other column type's existing behavior).
- `cosmic/sqlite/bind.tl`: on the UDF-argument side, the equivalent
  wrap using `value_type(n)`. On the bind (write) side, teach the
  default bind path to dispatch on `Blob` — a `Blob` value
  automatically calls the raw binding's `bind_blob`, anything else
  calls the raw `bind` — so a value read as a `Blob` and later bound
  back into a parameter round-trips as a BLOB without the caller
  having to remember to call `bind_blob` explicitly.
- Regenerate `cosmo.*` Teal types against the new cosmopolitan pin
  (no manual regen step — the build produces them from the bumped
  pin, per this repo's Type Generation doctrine).

This is a deliberate, scoped break: existing `cosmic.sqlite` callers
that read a BLOB column and treat the result as a plain Lua string
will now receive a `Blob` table/record instead. The project owner
confirmed this tradeoff is acceptable when the decision was made
(board item `3IlL8oOG`) — no back-compat shim, no dual-mode read
path.

## Non-goals

- No change to the cosmopolitan-side accessors themselves — this
  item only consumes `value_type`/`column_type`, landed by
  `3If5s4hN`.
- No change to how NULL, INTEGER, or FLOAT columns are represented —
  only BLOB gains a distinct type.
- No UDF-registration changes beyond wrapping argument values that
  already flow through the existing UDF-arg push path.

## Enablement

Blocked on `3If5s4hNeSCYCYLbOoyuYH1dq7T` (cosmic-lua/cosmopolitan):
this item cannot be built, or even fully specified for a build step,
until that repo ships `value_type`/`column_type` and cosmic bumps its
`3p/cosmos` pin to a release carrying them.
