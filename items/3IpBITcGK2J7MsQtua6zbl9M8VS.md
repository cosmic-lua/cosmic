## Evidence

Re-run 2026-09-03 against `origin/main` (`96afd807`):

    git show origin/main:docs/design/cast-sites.tsv | awk -F'\t' '$3=="incremental record construction"{print $1":"$2}'
    cosmic/fetch/init.tl:220
    cosmic/format/init.tl:118
    cosmic/quicksand/box/merge.tl:138
    cosmic/signal.tl:287
    cosmic/sqlite/init.tl:214
    cosmic/sqlite/init.tl:295
    cosmic/sqlite/row_iter.tl:64

7 sites, matching the outcome's Evidence section verbatim. The lines:

    cosmic/fetch/init.tl:220
      return setmetatable(fields as Response, response_mt) as Response -- cast: table seeded as record
    cosmic/format/init.tl:118
      items[#items + 1] = token as Item -- cast: parse is done; Item only adds fields
    cosmic/quicksand/box/merge.tl:138
      return acc as types.BoxOptions -- cast: dynamic walk rebuilt as the record it walked
    cosmic/signal.tl:287
      local M = {} as SignalModule -- cast: record built incrementally
    cosmic/sqlite/init.tl:214
        return iter as Rows -- cast: row_iter record to public Rows
    cosmic/sqlite/init.tl:295
        return iter as Rows -- cast: row_iter record to public Rows
    cosmic/sqlite/row_iter.tl:64
      local iter = setmetatable({} as Rows, { -- cast: table seeded as record

`_build/casts_baseline.tl` rows this lowers (grep against the
committed floor):

    grep -F -e '"cosmic/fetch/init.tl"' -e '"cosmic/format/init.tl"' \
      -e '"cosmic/quicksand/box/merge.tl"' -e '"cosmic/signal.tl"' \
      -e '"cosmic/sqlite/init.tl"' -e '"cosmic/sqlite/row_iter.tl"' _build/casts_baseline.tl
    ["cosmic/fetch/init.tl"] = 7,
    ["cosmic/format/init.tl"] = 5,
    ["cosmic/quicksand/box/merge.tl"] = 2,
    ["cosmic/signal.tl"] = 2,
    ["cosmic/sqlite/init.tl"] = 2,
    ["cosmic/sqlite/row_iter.tl"] = 1,

Only one site in this class lives in each of `fetch/init.tl`,
`format/init.tl`, `signal.tl` and `row_iter.tl`, so those drop by one
(7→6, 5→4, 2→1, 1→0); `merge.tl` also carries a *different* class's
site at line 135 (map view — the sibling item below), so this change
alone takes it 2→1, not to 0; `sqlite/init.tl` holds both its casts in
this class (214 and 295) and goes 2→0.

`cosmic/quicksand/box/merge.tl:135` is OUT of scope here — it belongs
to "map view of a declared value" (this outcome's sibling child); do
not touch it in this change, only line 138.

## Change

Each site casts a table built up field-by-field, or seeded empty and
filled after, to the record it satisfies once construction is done.
Teal checks a record LITERAL field by field but has nothing to say
about incremental construction; the fix is to write each as a literal
(or, where the fields genuinely arrive one at a time from closures,
declare the field set up front and assign the closures after — the
`row_iter.tl` shape named below):

- **`cosmic/fetch/init.tl:220`** — `fields` is assembled earlier in the
  same function; read the assembly and turn it into one `Response`
  record literal at the point all fields are known, so the
  `setmetatable(... as Response, response_mt) as Response` becomes
  `setmetatable(fields, response_mt)` typed to `Response` by the
  literal alone (or an explicit `: Response` on the local it's bound
  to, if `setmetatable`'s own return type needs the annotation).
- **`cosmic/format/init.tl:118`** — `token` already has every `Item`
  field by the time it's appended; construct it as an `Item` literal at
  its point of creation instead of building a looser table and casting
  it to `Item` at the append.
- **`cosmic/quicksand/box/merge.tl:138`** — `acc` is a dynamic walk's
  accumulator, re-typed to `types.BoxOptions` at the return. If the
  walk's shape is knowable at each assignment, build `acc` as a
  `types.BoxOptions` literal seeded with defaults and mutate typed
  fields through the walk instead of a plain map; if the walk's key set
  is genuinely dynamic (it may be — this is `merge_section`'s general
  path), this site may not close mechanically and should be re-flagged
  in the PR rather than force-fit.
- **`cosmic/signal.tl:287`** — `local M = {} as SignalModule`: `M` is
  the module table filled in by the `function M.foo()` definitions that
  follow. Declare `M: SignalModule` up front (an empty record literal
  typed by its declaration, `local M: SignalModule = {}`) rather than
  casting an untyped `{}`; Teal checks each subsequent `M.foo =`
  assignment against the declared field once `M` carries the type.
- **`cosmic/sqlite/init.tl:214,295`** — both `return iter as Rows`
  wrap a `row_iter` return in the public `Rows` alias. Once
  `row_iter.tl:64` (below) declares `iter` as `Rows` at its own
  construction, `init.tl`'s two callers pass an already-typed `Rows`
  through and both casts fall away for free — do this site AFTER
  `row_iter.tl:64` in the same PR, not before, so the intermediate
  state never needs its own cast.
- **`cosmic/sqlite/row_iter.tl:64`** — `local iter = setmetatable({} as Rows, {`:
  `iter`'s fields are assigned by the metatable's closures, not at
  this line. Give the local its declared type instead of casting the
  seed: `local iter: Rows = setmetatable({}, {` (or a `Rows` record
  literal carrying its known-at-construction fields, with the
  metatable's `__index`/iterator closures assigned after via `iter.x =`
  rather than inside the initial literal, if any field is not known
  yet at this line).

Regenerate the derived files and reconcile:

    bin/cosmic --make run _build/casts.tl --baseline
    bin/cosmic --make run _build/cast_sites.tl --reconcile

then confirm the class is empty (or, if `merge.tl:138` did not close
mechanically, confirm it is the only surviving row):

    git show HEAD:docs/design/cast-sites.tsv | awk -F'\t' '$3=="incremental record construction"'

and, only if the class is fully empty, delete the
`### incremental record construction` heading from `docs/design/casts.md`
(precedent: `git show cf416d85 -- docs/design/casts.md | grep '^-###'`
deleted `### proved-value narrowing` in the PR that emptied it). If
`merge.tl:138` survives, leave the heading and its "What closes it
here" prose in place, updated to note the one residual site.

Gate with `bin/cosmic --make ci`; `_build/cast_sites_test.tl` checks
the reconciled tsv against a fresh lexer walk and every `### ` heading.

## Non-goals

`cosmic/quicksand/box/merge.tl:135` (map view class) is not this
change's site — touching it here would collide with the sibling child
editing the same file at a nearby line.
