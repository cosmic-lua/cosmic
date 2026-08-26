## Goal

G3, under `3IOuSKFx` — the half of the dynamic-value residue whose
closure turned on checker questions. All four are now answered by
probe (every shape below applied and type-checked at refinement,
2026-08-26, tree at `d61b2cc9`, full `bin/cosmic --make ci` →
`ci: PASS (5 stages)` with the diff in place): **nine `from any` casts
close; one new cast appears with a truthful reason** (`table.pack`'s
`n` erased by mixed element types). `rand.choice` becomes generic —
the one public-API change, decided below.

## Evidence — the four questions, answered

Re-measured 2026-08-26 against main `d61b2cc9`:

| file | `from any` | all casts | lines | baseline row |
| --- | --- | --- | --- | --- |
| `cosmic/coverage/init.tl` | 6 (`:93`, `:96`, `:98`, `:115`, `:119`, `:124`) | 11 | 357 | `= 11` |
| `_tool/benchmark.tl` | 1 (`:183`, marker `:182`) | 1 | 368 | `= 1` |
| `_perf/run.tl` | 1 (`:132`, marker `:131`) | 1 | 391 | `= 1` |
| `cosmic/rand_test.tl` | 1 (`:145`) | 3 | 301 | `= 3` |

1. **`is` accepts a function SIGNATURE** — `v is function(any): any`
   and `v is function()` both type-check over `any` (probed). Two
   riders the probes also established, which the shapes below encode:
   **narrowing does not cross into a closure** (a guarded upvalue is
   `any` again inside a nested function — bind a typed local after the
   guard and close over that), and a signature guard can honestly
   state the RETURN type (`raw_create is function(any): thread`),
   which types every downstream use of the created value.
2. **The thread-cast split dissolves.** The three `thread as thread`
   casts (`:96`, `:98`, `:115`) were classed as C-binding-boundary
   work for whilp/cosmopolitan; re-measurement shows `v is thread`
   narrows, and typing `raw_create`'s guard as
   `function(any): thread` closes `:96`/`:98` outright via a typed
   `arm(cothread: thread)`. The `:115` resume site closes with the
   same typed upvalue; what survives is `:119`'s neighbor fact —
   `table.pack(coroutine.resume(...)).n` is `any` (probed: packing
   MIXED return types erases the element type and `n` with it, while
   `table.pack(1, 2, 3).n` is `integer`) — so that ONE cast stays,
   re-reasoned. Nothing moves to cosmopolitan.
3. **`rand.choice` goes generic** —
   `choice<T>(list: {T}): T | nil`, in both the function and the
   `RandModule` field (`choice: function<T>(list: {T}): T | nil`).
   Probed: the record-field generic compiles, `assert(choice({...}))`
   narrows to plain `T`, and the empty-list call still infers. All
   four call sites are in `cosmic/rand_test.tl`
   (`grep -rn "\.choice(" --include='*.tl' .`), so the public change
   is inference-invisible to any caller that exists. The doc comment's
   `@param`/`@return` move to `{T}` / `T | nil`.
4. **`_perf/run.tl:132` closes in value position** — probed:
   `(v is string and v) or "unknown"` types as `string`. Lift
   `rawget(arg, -1)` to a local first.

## Change

Five files; apply exactly these validated shapes.

**1. `cosmic/coverage/init.tl`** (`install_wrappers`): hoist both raw
lookups, guard once, and bind typed locals the closures capture:

```teal
  local co = coroutine as {string: any} -- cast: patch stdlib table
  local os_mod = os as {string: any} -- cast: patch stdlib table
  local raw_create = co["create"]
  local raw_exit = os_mod["exit"]
  -- The signature guards type raw_create's return as a real thread, so
  -- every downstream arm/resume site is plainly typed. A stdlib whose
  -- create or exit is not a function cannot occur; the guard leaves it
  -- unpatched rather than crashing mid-install.
  if not (raw_create is function(any): thread)
    or not (raw_exit is function(any, any)) then
    return
  end
  -- Narrowing does not cross into a closure; these typed locals carry it.
  local create_fn: function(any): thread = raw_create
  local exit_fn: function(any, any) = raw_exit
```

`arm` becomes `arm(cothread: thread)` with bare `ccov.arm(cothread)` /
`debug.sethook(cothread, on_line, "l")`; both wrapper closures call
`create_fn(f)` into a `cothread` local; the resume line keeps ONE
re-reasoned cast:

```teal
      -- Packing resume's mixed returns erases the element type to any.
      -- cast: table.pack's n field is an integer by contract
      return table.unpack(results, 2, results.n as integer)
```

and `os_mod["exit"]`'s wrapper calls `exit_fn(code, close)`. File ends
at 6 casts (2 patch-stdlib, 1 pack-n, 3 elsewhere in the file), 0
`from any`.

**2. `_tool/benchmark.tl`**: the existing
`type(bench_fn) ~= "function"` guard at `:156` becomes
`if not (bench_fn is function()) then` (same runtime test, credited by
the checker); add `local run_fn: function() = bench_fn` after it and
call `pcall(run_fn)` at `:183`, deleting the cast and its marker line.

**3. `_perf/run.tl:131–132`**:

```teal
  local argv_last = rawget(arg, -1)
  meta.bin = os.getenv("PERF_BIN") or (argv_last is string and argv_last) or "unknown"
```

**4. `cosmic/rand.tl`**: `choice` becomes
`local function choice<T>(list: {T}): T | nil` with `@param list {T}` /
`@return T | nil` (prose unchanged: nil only when the list is empty);
`RandModule.choice` becomes `function<T>(list: {T}): T | nil`.

**5. `cosmic/rand_test.tl:145`**: drop the cast —
`seen[assert(rand.choice({"x", "y", "z"}))] = true`.

**Validation trap, restated**: a bare `o/bin/cosmic --check types
cosmic/rand_test.tl` after editing `cosmic/rand.tl` reports the OLD
`any` return (the checker resolves `cosmic.*` from the running
binary's embedded source); gate with `bin/cosmic --make ci`, which
converges — refinement confirmed the full gate passes.

**The ratchet**: run exactly the printed regen —
`bin/cosmic --make run _build/casts.tl --baseline` — and commit.
Expected rows: `cosmic/coverage/init.tl` `= 11` → `= 6`;
`_tool/benchmark.tl` and `_perf/run.tl` rows absent (today `= 1`
each); `cosmic/rand_test.tl` `= 3` → `= 2`.

## Non-goals

- **No behaviour change to coverage instrumentation.** Wrappers still
  arm coroutines and flush on `os.exit`; the new impossible-miss guard
  leaves the stdlib entirely unpatched rather than half-patched or
  crashed. `--make coverage` must end `coverage: PASS` (refinement
  measured it: `PASS (240 files)`).
- **No `rand.choice` behaviour change** — same element, same nil on
  empty; the generic is inference-only and all callers live in the
  test file.
- **Do not touch `cosmic/_teal_engine.tl`, `cmd/cosmic/main.tl`,
  `cosmic/_seal_coverage.tl`** — sibling `3IQRDRwW` (PR #1396, in
  check); the two slices share only `_build/casts_baseline.tl`, whose
  conflict is the mechanical regen. Land whichever merges second via
  rebase + regen.
- **A reason rewrite is not a count trick**: the one surviving new
  cast names what is genuinely unnarrowable (pack-n erasure), probed.
- **No gate weakened**; the baseline moves only through the printed
  regen command.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c -- "-- cast: .*from any" cosmic/coverage/init.tl _tool/benchmark.tl _perf/run.tl cosmic/rand_test.tl`
  prints `0` for each (today `6`, `1`, `1`, `1`).
- `grep -c -- "-- cast:" cosmic/coverage/init.tl` prints `6` (today
  `11`) — the two patch-stdlib casts and the pack-n cast survive with
  their reasons, plus the file's three unrelated ones.
- `grep -n '"_tool/benchmark.tl"\|"_perf/run.tl"' _build/casts_baseline.tl`
  prints nothing (today `= 1` each).
- `grep -n '"cosmic/coverage/init.tl"\|"cosmic/rand_test.tl"' _build/casts_baseline.tl`
  shows `= 6` and `= 2` (today `= 11`, `= 3`).
- `bin/cosmic --make test cosmic/rand_test.tl cosmic/coverage/init_test.tl`
  ends `test: PASS (2 files)`.
- `o/bin/cosmic --make coverage` ends `coverage: PASS` — the patched
  wrappers still instrument and the seal still flushes.
- `git diff --stat origin/main...HEAD` names exactly six files: the
  five sources above and `_build/casts_baseline.tl`.

## Enablement

none needed. Every shape was applied and passed the full `--make ci`
gate during refinement; the two checker facts an implementer must not
rediscover (closure-boundary narrowing loss; the `cosmic.*`
embedded-source resolution trap) are stated inline where they bind.
