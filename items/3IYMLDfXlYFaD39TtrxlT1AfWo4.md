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
  available in the currently pinned tl already; **no `3p/tl/tl_pin.tl`
  bump is needed** for this slice.

**Correction from build attempt #1 (2026-09-03):** a builder tried
curating `Env` AND switching the three `_teal_ast.tl`/
`_teal_engine.tl` cast sites to consume it in one PR, and hit a
reproducible cold-build failure in `_types/types_gen.tl`'s own
self-compilation. Full repro in `3IortEJ5fOuRnJ7OpJMfuXzMkSX`. The
item was narrowed to curate `Env` alone, deferring the three
`report_types`/`loaded` cast removals to that follow-up.

**Correction from build attempt #2 (2026-09-03):** curating `Env`
ALONE, with zero consumer edits, ALSO fails to build — cold or warm.
`cosmic/_teal_engine.tl:239` (inside `process_source`, a call the
prior attempt did not touch) is:
```lua
local ok, result_or_err = pcall(tl.process_string, input, false, env, name)
```
`env`'s static type there is `any` (from `build_env(...): any,
string` / `env_cache: {string: any}` — both untouched by this item).
Once `Env` is curated, `_types/gentl.tl`'s already-curated `FUNCTIONS`
entry for `tl.process_string` resolves its 4th parameter from `any` to
the concrete `Env` record, and tl's `pcall` argument-checking rejects
an `any`-typed argument there — reproduced twice, deterministically,
including with a clean `rm -rf o && bin/cosmic --make fetch &&
bin/cosmic --make build`:
```
.../cosmic/_teal_engine.tl:239:73: error: argument 4: got <any type>, expected Env
```
Confirmed causal: reverting only the `_types/gentl.tl`/
`_types/gentl_test.tl` diff (`git stash`) restores a clean cold build;
reapplying it (`git stash pop`) reproduces the failure identically.

So curating `Env` has exactly one real consumer today, unavoidably:
this `pcall` call site, which is otherwise structurally forced to
type-check against `Env` the moment it exists, regardless of whether
`build_env`/`process_source`'s own DECLARED signatures change. This
item's `## Change` now includes the one minimal fix that call site
needs — an explicit cast, not a signature change — which is narrower
than and does not overlap with `3IortEJ5fOuRnJ7OpJMfuXzMkSX`'s scope
(that item still owns `build_env`'s and `process_source`'s declared
return types and the two `{string: any}` casts at lines ~231-232).

## Change

Curate a minimal `tl.Env` into `_types/gentl.tl`, following the
existing `Result`/`CheckOptions`/`EnvOptions` pattern (a hand-written
record body in the `PRELUDE` string, plus a `RECORD_FIELDS` entry that
`generate()`'s `verify_record` checks against the pinned source):

- add `Env = true` to `NAMED`
- add `RECORD_FIELDS["Env"] = {"report_types", "loaded"}` — only the
  two fields the follow-up item's `_teal_engine.tl` sites read;
  `Env` stays a curated subset like every other record here (the
  other six upstream `Env` fields are not read by any cast site in
  this class and are not curated — see Non-goals)
- add to the `PRELUDE` string:
  ```
  record Env
    report_types: boolean
    loaded: {string: Result}
  end
  ```
  (`Result` is already `NAMED`, so `loaded`'s value type resolves with
  no further change)
- `_types/gentl_test.tl`: its `erase()` unit test for `tl.new_env`'s
  return exercises the exact function this change retypes — update
  its expected erased-type string from `"any"` to `"Env"` (the test's
  own job is to pin what `erase()` does; this is not a scope
  violation, it is keeping that pin accurate for the type it now
  asserts).

Adding `Env` to `NAMED` is sufficient by itself for `erase()` to stop
mapping it to `any`: `tl.new_env`'s already-curated `FUNCTIONS` entry
picks up the new type automatically, so its generated declaration
becomes `function(? EnvOptions): (Env, string)` with no other generator
code change.

**The one required consumer-side fix** (see "Correction from build
attempt #2" above — this is not optional, the build does not pass
without it, cold or warm): in `cosmic/_teal_engine.tl`'s
`process_source`, at the `pcall(tl.process_string, input, false, env,
name)` call (currently line 239), change the argument to `env as Env`
with a trailing `-- cast: env's declared type stays any until
3IortEJ5fOuRnJ7OpJMfuXzMkSX retypes build_env/process_source; this
cast only satisfies tl.process_string's now-curated 4th parameter and
is removed by that follow-up, not by this item`. Do NOT change
`env`'s declared type, `build_env`'s declared return, `process_source`'s
declared return, `env_cache`'s declared type, or touch the two
`{string: any}` casts at lines ~231-232 — all of those stay
`3IortEJ5fOuRnJ7OpJMfuXzMkSX`'s job unchanged.

This adds one new cast site to `cosmic/_teal_engine.tl` (a file
already in `_build/casts_baseline.tl`'s ratchet). Measure its current
row before this change (`grep -n 'cosmic/_teal_engine.tl' -A1
_build/casts_baseline.tl` or equivalent) and update it to reflect the
one added cast; do the same for `docs/design/cast-sites.tsv` (add one
row for this new site, do not touch the three existing rows the
follow-up item owns) via `bin/cosmic --make run _build/casts.tl
--baseline` and `bin/cosmic --make run _build/cast_sites.tl
--reconcile`, then commit both. `_build/casts_test.tl`/
`_build/cast_sites_test.tl` fail until they match.

Verify with `bin/cosmic --make ci` passing, AND a genuinely cold
build succeeding — `rm -rf o && bin/cosmic --make fetch && bin/cosmic
--make build` — since this is exactly the scenario both prior build
attempts found broken; confirming a cold build is this item's own
proof the fix is complete.

No `3p/tl/tl_pin.tl` bump: everything cited above is read from the tl
this tree already has pinned (`3p/tl/tl_pin.tl`'s `version =
"0.24.8"`), fetched fresh for this refinement (`bin/cosmic --make
fetch` → `fetch: PASS (2 pins)`) and quoted from `o/3p/tl/tl.tl`.

## Non-goals

- The consumer-side change `3IortEJ5fOuRnJ7OpJMfuXzMkSX` owns —
  `build_env`'s and `process_source`'s DECLARED return types
  (`any, string` → `tl.Env | nil, string`), `env_cache`'s declared
  type, and the two `{string: any}` casts at lines ~231-232 reading
  `report_types`/`loaded` — is unchanged by this item. This item adds
  exactly one narrow, temporary `env as Env` cast at the `pcall` call
  site (see Change), forced into existence by curating `Env` at all,
  not a step toward that follow-up's broader retyping.
- The other 15 of the 18 `tl compiler surface` sites stay open:
  `_tool/discover.tl`, `_tool/coverage/lines.tl`, `_types/tlast.tl:106`,
  `_types/tlast_test.tl:60`, `cosmic/_teal_ast_test.tl`, and
  `cosmic/_teal_discard.tl:183,205`. `tl.Node` is upstream a
  deliberately empty interface (`o/3p/tl/tl.tl:673-675`), not an
  uncurated-but-available record the way `Env` was — closing these
  needs a `teal-language/tl` change that publishes real node fields,
  and **no session working this board has push/PR access to that
  repository**; do not attempt an upstream tl PR from here.
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
