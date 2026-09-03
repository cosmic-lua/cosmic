## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **tl compiler surface** class, 18 sites
(`docs/design/cast-sites.tsv`). Files: `_tool/coverage/lines.tl` 3;
`_tool/discover.tl` 3; `cosmic/_teal_ast_test.tl` 3;
`cosmic/_teal_discard.tl` 3; `cosmic/_teal_engine.tl` 3;
`_types/tlast.tl` 2; `_types/tlast_test.tl` 1.

Refining this item (against the pinned `v0.24.8`, fetched fresh —
`bin/cosmic --make fetch` → `fetch: PASS (2 pins)`) found the class is
not uniform, which changes what "closes it" means:

- **Most of the 18** (`_tool/discover.tl`, `_tool/coverage/lines.tl`,
  `_types/tlast.tl:106`, `_types/tlast_test.tl:60`,
  `cosmic/_teal_ast_test.tl`, `cosmic/_teal_discard.tl:183,205`) read a
  raw AST-node field (`kind`, `tk`, `y`, `yend`, `e2`, `if_blocks`) or
  treat a `Node`/`{Node}` value as an array. Upstream, `tl.Node` is not
  merely un-curated — it is a deliberately **empty** interface:
  `o/3p/tl/tl.tl:673-675` reads verbatim
  ```
     -- abstract type
     interface Node
     end
  ```
  The real, field-bearing `Node` record lives at `tl.tl:2201` but is
  `local`, never exported as `tl.Node`. No mechanism in this tree can
  give these reads a type without an upstream `teal-language/tl`
  change publishing real node fields — see Non-goals for why that stays
  out of reach here.
- **Three of the 18** are a different case: `cosmic/_teal_engine.tl`
  lines 175, 231 and 232 cast an `env` value to `{string: any}` only to
  read/write `report_types` and `loaded`. tl's own `Env` record already
  declares both — `o/3p/tl/tl.tl:578-588`:
  ```
     record Env
        globals: {string:Variable}
        modules: {string:Type}
        module_filenames: {string:string}
        loaded: {string:Result}
        loaded_order: {string}
        reporter: TypeReporter
        keep_going: boolean
        report_types: boolean
        defaults: CheckOptions
     end
  ```
  but `_types/gentl.tl` never curates `Env` — it is absent from both
  `NAMED` and `RECORD_FIELDS` — so `tl.new_env`'s generated return type
  erases to `any` and every read through it costs a cast. This is
  available in the currently pinned tl already; **no pin bump is
  needed** for this slice.

## Change

Curate a minimal `tl.Env` into `_types/gentl.tl`, following the
existing `Result`/`CheckOptions`/`EnvOptions` pattern (a hand-written
record body in the `PRELUDE` string, plus a `RECORD_FIELDS` entry that
`generate()`'s `verify_record` checks against the pinned source):

- add `Env = true` to `NAMED`
- add `RECORD_FIELDS["Env"] = {"report_types", "loaded"}` — only the
  two fields this class's `_teal_engine.tl` sites read; `Env` stays a
  curated subset like every other record here (the other six upstream
  `Env` fields are not read by any cast site in this class and are not
  curated — see Non-goals)
- add to the `PRELUDE` string:
  ```
  record Env
    report_types: boolean
    loaded: {string: Result}
  end
  ```
  (`Result` is already `NAMED`, so `loaded`'s value type resolves with
  no further change)

Adding `Env` to `NAMED` is sufficient by itself for `erase()` to stop
mapping it to `any`: `tl.new_env`'s already-curated `FUNCTIONS` entry
picks up the new type automatically, so its generated declaration
becomes `function(? EnvOptions): (Env, string)` with no other generator
code change.

Then, at the two places that manufacture the erased `any` today:

- `cosmic/_teal_ast.tl`: change `teal_ast.new_env`'s declared return
  from `any, string` to `tl.Env | nil, string` (both the `record
  teal_ast` field and the function signature), and its two `@return
  any` doc comments to `@return tl.Env | nil`.
- `cosmic/_teal_engine.tl`:
  - `build_env`'s declared return changes from `any, string` to
    `tl.Env | nil, string`; drop its `env as {any: any}` cast (line
    ~175) and write `env.report_types = true` directly.
  - `process_source`'s `env_cache` changes from `{string: any}` to
    `{string: tl.Env}`, and its local `env` from `any` to `tl.Env |
    nil`; drop the two `as {any: any}` casts (lines ~231-232) and write
    `env.loaded[name] = nil` directly.

Land these together with:

- `_build/casts_baseline.tl`'s `cosmic/_teal_engine.tl` row moves from
  `4` to `1` — run `bin/cosmic --make run _build/casts.tl --baseline`
  and commit the result; `_build/casts_test.tl` fails until this
  matches.
- `docs/design/cast-sites.tsv` drops its three now-gone rows
  (`cosmic/_teal_engine.tl` 175, 231, 232) — run `bin/cosmic --make run
  _build/cast_sites.tl --reconcile` and commit the result;
  `_build/cast_sites_test.tl` fails until it matches.
- `bin/cosmic --make ci` passes (types, fmt, lint, coverage,
  example). No new test is needed beyond these: `_types/gentl_test.tl`
  and `3p/tl/tl_test.tl`'s conformance checks already exercise every
  curated record and function against the pinned source on every
  build, which is what pins `RECORD_FIELDS["Env"]` to the real v0.24.8
  shape rather than to a guess.

No pin bump: everything cited above is read from the tl this tree
already has pinned (`3p/tl/tl_pin.tl`'s `version = "0.24.8"`), fetched
fresh for this refinement (`bin/cosmic --make fetch` → `fetch: PASS (2
pins)`) and quoted from `o/3p/tl/tl.tl`.

## Non-goals

- The other 15 of the 18 `tl compiler surface` sites stay open:
  `_tool/discover.tl`, `_tool/coverage/lines.tl`, `_types/tlast.tl:106`,
  `_types/tlast_test.tl:60`, `cosmic/_teal_ast_test.tl`, and
  `cosmic/_teal_discard.tl:183,205`. `tl.Node` is upstream a
  deliberately empty interface (`o/3p/tl/tl.tl:673-675`), not an
  uncurated-but-available record the way `Env` was — closing these
  needs a `teal-language/tl` change that publishes real node fields,
  and **no session working this board has push/PR access to that
  repository**; do not attempt an upstream tl PR from here. If a
  cosmic-lua-owned fork of tl is ever pinned in place of upstream, or
  upstream tl accepts and ships such a change on its own, this floor
  reopens as a new item then — not by guessing at it now.
- `_types/tlast.tl:106` and `:331`: this file `load()`s a *second*,
  private copy of `tl.lua` rather than using `require("tl")`, so
  `_types/gentl.tl`'s curated `tl.d.tl` type never applies to it no
  matter what gets curated there. Not in scope for any `gentl.tl`
  change.
- `cosmic/_teal_discard.tl:258` (`rep["get_report"]`): closing this
  would mean curating `TypeReporter`/`TypeReport` and/or routing
  through the already-public `tl.get_types(result): TypeReport,
  TypeReporter`, which also means reshaping `issues()`'s signature to
  carry a `Result` instead of a bare `env`/`ast` pair — an independent
  change; leave it for a later item.
- Do not curate any other `Env` field (`globals`, `modules`,
  `module_filenames`, `loaded_order`, `reporter`, `keep_going`,
  `defaults`) in this change — none is read by a site in this class;
  add one only when a real site needs it.
- Do not touch `3p/tl/tl_pin.tl` — this change needs no pin bump.
