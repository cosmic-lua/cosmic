## Evidence

Re-run 2026-09-03 against `origin/main` (`96afd807`), the class the
outcome carried forward:

    git show origin/main:docs/design/cast-sites.tsv | awk -F'\t' '$3=="decoded data shaping"{print $1":"$2}'
    _build/casts.tl:90
    _tool/coverage/baseline.tl:132
    _tool/coverage/baseline.tl:138
    _tool/coverage/baseline_test.tl:486
    cmd/cosmic/embed_gen.tl:294
    cmd/cosmic/embed_gen.tl:334
    cosmic/literal_example.tl:20

7 sites, the seven rows the outcome's Evidence section names verbatim.
The lines themselves (`sed -n '<n>p' <file>`):

    _build/casts.tl:90
      out[file] = n as integer -- cast: the baseline holds counts
    _tool/coverage/baseline.tl:132
      local t = v as {string: any} -- cast: runtime-checked table above
    _tool/coverage/baseline.tl:138
      return {covered = covered as integer, total = total as integer} -- cast: math.type checked above
    _tool/coverage/baseline_test.tl:486
      local got = new_rows[path] as {string: any} -- cast: literal row, known Entry shape
    cmd/cosmic/embed_gen.tl:294
      local named = (declared as {string: any}).cosmic
    cmd/cosmic/embed_gen.tl:334
      local cosmos = (pin as {string: any}).version
    cosmic/literal_example.tl:20
      local cfg = raw as {string: any} -- cast: the reader returns a plain table

Every one of these files' casts belong entirely to this class — the
committed floor and the class total match exactly, so this change
zeroes all seven files in `_build/casts_baseline.tl`:

    grep -F -e '"_build/casts.tl"' -e '"_tool/coverage/baseline.tl"' \
      -e '"_tool/coverage/baseline_test.tl"' -e '"cmd/cosmic/embed_gen.tl"' \
      -e '"cosmic/literal_example.tl"' _build/casts_baseline.tl
    ["_build/casts.tl"] = 1,
    ["_tool/coverage/baseline.tl"] = 2,
    ["_tool/coverage/baseline_test.tl"] = 1,
    ["cmd/cosmic/embed_gen.tl"] = 2,
    ["cosmic/literal_example.tl"] = 1,

`_build/casts.tl` (1), `_tool/coverage/baseline.tl` (2),
`_tool/coverage/baseline_test.tl` (1), `cmd/cosmic/embed_gen.tl` (2)
and `cosmic/literal_example.tl` (1) all drop to 0 — every row this
class touches disappears from the baseline.

`cosmic.shape` (`cosmic/shape.tl`) already exists and does exactly this
job: `shape.into(raw, SPEC)` validates a decoded `any` value against a
declared `Spec` (built from `shape.record`/`shape.string`/
`shape.integer`/`shape.map`/... combinators) and hands it back typed in
one call, target type inferred from the caller's own annotation
(`local x: T | nil, string = shape.into(raw, SPEC)`, or
`check.must(shape.into(raw, SPEC))` in a test with an explicit local
type). Every site above is that exact shape: a value that came out of
`literal.parse`, a decoded baseline row, a decoded pin, or a loaded
config table, read field by field with a cast per field.

## Change

Route each site through `cosmic.shape` instead of a cast, deleting the
`as` at each of the seven lines above:

- **`_build/casts.tl:90`** — `out[file] = n as integer`: `n` comes from
  decoding `_build/casts_baseline.tl` (a literal chunk). Declare a
  `shape.record({[file] = shape.integer, ...})`-shaped spec for the
  baseline map (or, since the baseline is a flat `{string: integer}`,
  `shape.map(shape.string, shape.integer)` if a bare map combinator
  covers it — use `shape.integer_map` if the key is the string filename
  and `map` is meant for non-string keys; read `cosmic/shape.tl`'s
  combinator doc comments to pick the right one) and call
  `shape.into` on the decoded table once, before iterating.
- **`_tool/coverage/baseline.tl:132,138`** — the same decoded-baseline
  read: build the `Entry` (`{covered: integer, total: integer}`) as a
  `shape.record`, call `shape.into` once per row instead of casting `v`
  to `{string: any}` and then casting the two fields off it.
- **`_tool/coverage/baseline_test.tl:486`** — `new_rows[path]` is a
  decoded row read back for a test assertion; give it the same `Entry`
  spec and drop the cast.
- **`cmd/cosmic/embed_gen.tl:294,334`** — `declared` and `pin` are
  decoded config values; declare specs for the `.cosmic` and `.version`
  fields actually read and call `shape.into` before the field access.
- **`cosmic/literal_example.tl:20`** — `raw` is what
  `cosmic.literal`'s reader returns; declare its shape and validate.

Each replacement is `value, err = shape.into(raw, SPEC)` with the
existing error-handling pattern at that call site (most already sit
behind a fallible return or a test's `check.must`), never a bare
`check.must` swallowing a shape mismatch a caller could act on.

After all seven casts are gone, regenerate the committed baseline and
reconcile the site inventory:

    bin/cosmic --make run _build/casts.tl --baseline    # rewrites _build/casts_baseline.tl
    bin/cosmic --make run _build/cast_sites.tl --reconcile   # rewrites docs/design/cast-sites.tsv

then confirm the class is empty:

    git show HEAD:docs/design/cast-sites.tsv | awk -F'\t' '$3=="decoded data shaping"'   # (after committing) — empty

and delete the now-empty `### decoded data shaping` heading (and its
body, through the next `###`) from `docs/design/casts.md`, following
the precedent `git show cf416d85 -- docs/design/casts.md | grep '^-###'`
(that commit deleted `### proved-value narrowing` the same way, in the
same PR that emptied its class).

Gate with `bin/cosmic --make ci` — `_build/cast_sites_test.tl` checks
the reconciled tsv against a fresh walk and against every remaining
`### ` heading, so a stray site or an un-deleted heading fails there.
