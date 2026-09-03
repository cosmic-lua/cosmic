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
  raw AST-node field or treat a `Node`/`{Node}` value as an array.
  Upstream, `tl.Node` is a deliberately **empty** interface
  (`o/3p/tl/tl.tl:673-675`); the real, field-bearing record is
  `local`, never exported as `tl.Node`. No mechanism in this tree can
  give these reads a type without an upstream `teal-language/tl`
  change — see Non-goals.
- **Three of the 18** are a different case: `cosmic/_teal_engine.tl`
  lines 175, 231 and 232 cast an `env` value to `{string: any}` only to
  read/write `report_types` and `loaded`. tl's own `Env` record already
  declares both (`o/3p/tl/tl.tl:578-588`), but `_types/gentl.tl` never
  curates `Env`, so `tl.new_env`'s generated return type erases to
  `any`. This is available in the currently pinned tl already; **no
  `3p/tl/tl_pin.tl` bump is needed** for this slice.

**Correction from build attempt #1 (2026-09-03):** curating `Env` AND
switching the three `_teal_ast.tl`/`_teal_engine.tl` cast sites to
consume it in one PR hits a reproducible cold-build failure in
`_types/types_gen.tl`'s own self-compilation. Full repro in
`3IortEJ5fOuRnJ7OpJMfuXzMkSX`. The item was narrowed to curate `Env`
alone, deferring the three `report_types`/`loaded` cast removals to
that follow-up.

**Correction from build attempt #2:** curating `Env` ALONE still fails
to build. Once `Env` exists, `_types/gentl.tl`'s already-curated
`FUNCTIONS` entry resolves `tl.process_string`'s 4th parameter from
`any` to `Env`, and any call site passing an `any`-typed `env` value
there now fails to type-check. `cosmic/_teal_engine.tl:239`
(`pcall(tl.process_string, input, false, env, name)`, `env`'s static
type `any` via `build_env`/`env_cache`) is one such site:
```
.../cosmic/_teal_engine.tl:239:73: error: argument 4: got <any type>, expected Env
```
Fixed with a narrow, temporary `env as Env` cast at that call only
(see Change) — not a signature change, and not
`3IortEJ5fOuRnJ7OpJMfuXzMkSX`'s job.

**Correction from build attempt #3:** fixing attempt #2's site was not
sufficient — a SECOND site has the same shape.
`cosmic/_teal_ast_test.tl:51` (`tl.process_string(code, false, env,
"probe.tl")`, no `pcall`) fails identically:
```
cosmic/_teal_ast_test.tl:51:49: error: argument 3: got <any type>, expected Env
```
`env` there comes from `require("cosmic._teal_ast").new_env(...)` —
`cosmic/_teal_ast.tl`'s OWN wrapper, declared to return `any, string`
(`cosmic/_teal_ast.tl:22`, also `3IortEJ5fOuRnJ7OpJMfuXzMkSX`'s job to
retype), so this `env` stays `any` regardless of this item's Change.

**Exhaustive audit, run to rule out a fourth surprise.** Every call
site of `tl.new_env`, `tl.init_env`, or `tl.process_string` in the
tree (excluding `o/`, excluding comments):
```
$ grep -rn "tl\.new_env\|tl\.init_env\|tl\.process_string" --include="*.tl" . | grep -v "^\./o/"
```
resolves to exactly these non-comment call sites:
- `cosmic/_teal_ast.tl:70` — `return tl.new_env({...})`, INSIDE
  `teal_ast.new_env` itself, returned as that function's own declared
  `any, string` — a concrete `Env` widening to a declared `any` return
  is always legal, no cast needed, not a call-site problem.
- `cosmic/_teal_engine.tl:239` — fixed by this item (attempt #2's
  cast).
- `cosmic/_teal_ast_test.tl:51` — fixed by this item (attempt #3's
  cast, see Change).
- `_types/tl_conformance_test.tl:59-65,86` — `env` is bound directly
  from `tl.init_env(...)`/`tl.new_env(...)`, so it is ALREADY typed
  `Env` (not boxed through an `any`-declared wrapper); passing it to
  `tl.process_string` at line 86 type-checks with no cast needed.
- `_types/gentype.tl:394-395` — same shape: `local env =
  tl.init_env(true)` is directly `Env`-typed, then
  `pcall(tl.process_string, output, false, env, name)` matches with no
  cast needed.
- `3p/tl/tl_test.tl:27,38,56` — all three pass a literal `nil` for
  `env`, not a variable; `nil` satisfies any parameter type, no cast
  needed.

So exactly two call sites are forced by curating `Env`, both because
they route through an intermediate wrapper (`build_env`/`env_cache`,
`teal_ast.new_env`) still declared `any` pending
`3IortEJ5fOuRnJ7OpJMfuXzMkSX`. No third site exists in the tree today.

## Change

Curate a minimal `tl.Env` into `_types/gentl.tl`, following the
existing `Result`/`CheckOptions`/`EnvOptions` pattern (a hand-written
record body in the `PRELUDE` string, plus a `RECORD_FIELDS` entry that
`generate()`'s `verify_record` checks against the pinned source):

- add `Env = true` to `NAMED`
- add `RECORD_FIELDS["Env"] = {"report_types", "loaded"}` — only the
  two fields the follow-up item's `_teal_engine.tl` sites read
- add to the `PRELUDE` string:
  ```
  record Env
    report_types: boolean
    loaded: {string: Result}
  end
  ```
  (`Result` is already `NAMED`, so `loaded`'s value type resolves with
  no further change)
- `_types/gentl_test.tl`: update its `erase()` unit test for
  `tl.new_env`'s return from expecting `"any"` to expecting `"Env"`
  (the test's job is to pin what `erase()` does for this exact
  function; keeping it accurate is not scope creep).

Adding `Env` to `NAMED` is sufficient by itself for `erase()` to stop
mapping it to `any`; `tl.new_env`'s already-curated `FUNCTIONS` entry
picks up the new type automatically.

**The two required consumer-side casts** (both forced into existence
by curating `Env` at all — see the audit above; the build does not
pass cold or warm without both):

1. `cosmic/_teal_engine.tl`'s `process_source`, at
   `pcall(tl.process_string, input, false, env, name)` (currently
   line 239): change the argument to `env as Env` with a trailing
   `-- cast: env's declared type stays any until
   3IortEJ5fOuRnJ7OpJMfuXzMkSX retypes build_env/process_source; this
   cast only satisfies tl.process_string's now-curated 4th parameter
   and is removed by that follow-up, not by this item`.
2. `cosmic/_teal_ast_test.tl`, at `tl.process_string(code, false, env,
   "probe.tl")` (currently line 51): change the argument to `env as
   Env` with a trailing `-- cast: env comes from teal_ast.new_env,
   still declared any pending 3IortEJ5fOuRnJ7OpJMfuXzMkSX; this cast
   only satisfies tl.process_string's now-curated 3rd parameter here
   and is removed by that follow-up, not by this item`.

Do NOT change `env`'s declared type, `build_env`'s declared return,
`process_source`'s declared return, `env_cache`'s declared type,
`teal_ast.new_env`'s declared return, or touch the two `{string: any}`
casts at `_teal_engine.tl` lines ~231-232 — all of those stay
`3IortEJ5fOuRnJ7OpJMfuXzMkSX`'s job unchanged.

This adds two new cast sites (one each in `cosmic/_teal_engine.tl` and
`cosmic/_teal_ast_test.tl`, both already in `_build/casts_baseline.tl`'s
ratchet). Measure each file's current row before this change and
update both to reflect the added cast; do the same for
`docs/design/cast-sites.tsv` (add two rows for these new sites, do not
touch the three existing `_teal_engine.tl` rows the follow-up item
owns) via `bin/cosmic --make run _build/casts.tl --baseline` and
`bin/cosmic --make run _build/cast_sites.tl --reconcile`, then commit
both. `_build/casts_test.tl`/`_build/cast_sites_test.tl` fail until
they match.

Verify with `bin/cosmic --make ci` passing, AND a genuinely cold
build succeeding — `rm -rf o && bin/cosmic --make fetch && bin/cosmic
--make build` — since this is exactly the scenario all three prior
build attempts found broken; confirming a cold build is this item's
own proof the fix is complete. If a cold build STILL fails at a
different site than the two named above, the exhaustive audit above
was wrong somewhere — STOP and report the new site with its exact
error text rather than patching it silently; do not attempt a fourth
guess.

No `3p/tl/tl_pin.tl` bump: everything cited above is read from the tl
this tree already has pinned (`3p/tl/tl_pin.tl`'s `version =
"0.24.8"`), fetched fresh for this refinement.

## Non-goals

- The consumer-side change `3IortEJ5fOuRnJ7OpJMfuXzMkSX` owns —
  `build_env`'s, `process_source`'s, and `teal_ast.new_env`'s DECLARED
  return types, `env_cache`'s declared type, and the two `{string:
  any}` casts at `_teal_engine.tl` lines ~231-232 — is unchanged by
  this item. This item adds exactly the two narrow, temporary `env as
  Env` casts named in Change, forced into existence by curating `Env`
  at all, not a step toward that follow-up's broader retyping.
- The other 15 of the 18 `tl compiler surface` sites stay open
  (raw `Node`-field reads — see Goal). `tl.Node` is upstream a
  deliberately empty interface; closing these needs a
  `teal-language/tl` change, and **no session working this board has
  push/PR access to that repository**; do not attempt an upstream tl
  PR from here.
- `_types/tlast.tl:106` and `:331`: this file `load()`s a *second*,
  private copy of `tl.lua` rather than using `require("tl")`, so
  `_types/gentl.tl`'s curated type never applies to it. Not in scope.
- `cosmic/_teal_discard.tl:258` (`rep["get_report"]`): an independent
  change (curating `TypeReporter`/`TypeReport` and reshaping
  `issues()`'s signature); leave it for a later item.
- Do not curate any other `Env` field (`globals`, `modules`,
  `module_filenames`, `loaded_order`, `reporter`, `keep_going`,
  `defaults`) — none is read by a site in this class.
- Do not touch `3p/tl/tl_pin.tl` — this change needs no pin bump.
