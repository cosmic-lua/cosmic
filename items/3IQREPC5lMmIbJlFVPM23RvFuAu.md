## Goal
G3, under `3IOuSKFx` — the undecidable-by-reading half of the dynamic-value
residue: the sites whose closure turns on a question only the checker can
answer (does Teal's `is` accept a function type?) or on an API decision
(should `rand.choice` return the element type?). Its sibling `3IQRDRwW` takes
the six that read as settled; this one exists so those six are not held
behind these.

## Change
Measured 2026-08-25 against `47adef2c` (`git ls-files '*.tl' | xargs grep
-n -- "-- cast: .*from any"`, `grep -c -- "-- cast:" <file>`, `wc -l`):

| file | `from any` | all casts | lines |
| --- | --- | --- | --- |
| `cosmic/coverage/init.tl` | 6 (`:93`, `:96`, `:98`, `:115`, `:119`, `:124`) | 11 | 357 |
| `_tool/benchmark.tl` | 1 (`:182`) | 1 | 368 |
| `_perf/run.tl` | 2 (`:132`, and `:165` — claimed by `3IQQeXC3`) | 2 | 392 |
| `cosmic/rand_test.tl` | 1 (`:145`) | 3 | 301 |

The four questions refinement has to answer, each with the command or
experiment that answers it:

1. **Does `is` narrow to a function type?** `cosmic/coverage/init.tl:93`
   (`co["create"] as function(any): any`) and `:124` (`os_mod["exit"] as
   function(any, any)`), and `_tool/benchmark.tl:182` (`pcall(bench_fn as
   function())`), all cast an indexed value to a function SIGNATURE. If
   `x is function(any): any` typechecks, they close like every other guard;
   if it does not (a type test can only ask `type(x) == "function"`, which
   says nothing about arity), they are irreducible AS TYPED CASTS and close
   instead by carrying a truer reason than `from any` — the file already
   uses `-- cast: patch stdlib table` for the two table-level casts beside
   them, and `stdlib patch table index` names what is actually happening.
   Answer it by writing the guard into a scratch `.tl` and running
   `bin/cosmic --check types` on it; record the result in the refined spec.
2. **Which of `cosmic/coverage/init.tl`'s six are even this item's?**
   `3IOuSKFx`'s own measurement says three of the six are the C-binding
   boundary class — the `thread as thread` casts at `:96`, `:98`, `:115`,
   which cross into `cosmo.cov`/`debug.sethook` — and close in
   whilp/cosmopolitan, not here. So this slice must claim `:93`, `:119`,
   `:124` only, and the file's ratchet row falls without vanishing.
   Re-measure the split before writing the row.
3. **Should `rand.choice` return the element type?** `cosmic/rand.tl:96`
   declares `choice(list: {any}): any`, which is why
   `cosmic/rand_test.tl:145` casts. Its only callers are that test file
   (`grep -rn "\.choice(" --include='*.tl' .` finds four call sites, all in
   `cosmic/rand_test.tl`), so a generic `choice<T>(list: {T}): T | nil`
   costs one public signature and closes the site at its source rather than
   at its use. This is a public-API change to a `cosmic.*` module: decide
   it, then state the exact declaration and check whether
   `cosmic --docs cosmic.rand` needs anything beyond the regenerated entry.
4. **`_perf/run.tl:132`.** `os.getenv("PERF_BIN") or rawget(arg, -1) as
   string or "unknown"` — the cast sits inside an `or` chain, so closing it
   restructures the expression (lift `rawget(arg, -1)` to a local, guard it
   with `is string`, then build the fallback). `3IQQeXC3` deliberately left
   it here. Confirm it is still the file's only remaining `from any` after
   that sibling lands.

## Non-goals
- **The three `thread` casts in `cosmic/coverage/init.tl` (`:96`, `:98`,
  `:115`) are not this slice's** — they are the C-binding boundary class.
- **`cosmic/_teal_engine.tl`, `cmd/cosmic/main.tl` and
  `cosmic/_seal_coverage.tl` belong to the sibling `3IQRDRwW`.** Do not touch
  them; the two slices share only `_build/casts_baseline.tl`.
- **No behaviour change to coverage instrumentation.** The stdlib patching
  in `install_wrappers` must keep arming coroutines and flushing on
  `os.exit`; `--make coverage` must still end `coverage: PASS` with the
  ratchet ok.
- **A reason rewrite is not a count trick.** If a site is irreducible, its
  new reason must name what is actually unnarrowable at that line; a
  reworded `from any` that says no more than `from any` did is a bounce.
- **No gate weakened.** `_build/casts_baseline.tl` moves only through
  `bin/cosmic --make run _build/casts.tl --baseline`, the command the gate
  prints.

## Acceptance
Provisional — fixed by the refinement that answers the four questions:
- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c -- "-- cast: .*from any" cosmic/rand_test.tl _perf/run.tl
  _tool/benchmark.tl` prints the numbers the refined spec states (today
  `1`, `2`, `1`).
- `grep -n '"cosmic/coverage/init.tl"' _build/casts_baseline.tl` shows the
  row the refined spec states (today `= 11`).
- `bin/cosmic --make test cosmic/rand_test.tl` ends `test: PASS (1 file)`.
- `o/bin/cosmic --make coverage` ends `coverage: PASS` with `coverage
  ratchet ok`.
- `git diff origin/main -- _build/public_surface_baseline.tl` is empty.

## Enablement
none needed to refine — questions 1 and 3 are answered by one scratch file
and `bin/cosmic --check types`, question 2 by re-reading the six sites, and
question 4 by re-measuring after `3IQQeXC3` lands. Refining this item does
need a built tree (`bin/cosmic --make build`), which is why it is cut away
from its sibling: the sibling is decidable from a read alone.
