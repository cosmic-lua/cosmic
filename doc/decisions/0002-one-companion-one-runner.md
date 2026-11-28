# 0002 one companion file, one runner

status: accepted

## context

A module of the standard library has up to four companions, and each
followed its own layout and runner:

- tests: `local function test_*` in `<module>_test.tl`, run by `cosmic test`;
- fuzz properties: [`Fuzz.run`] called from a `test_*` of
  `<module>_fuzz_test.tl`, run by `cosmic test` at `FUZZ_ITERS` inputs and
  by the weekly `fuzz.yml` at many;
- examples: the record `Example` that `<module>_example.tl` returns, run
  by `cosmic test` and shown by `cosmic docs`;
- benches: `bench.case` calls in a script under `bench/`, run by hand as
  `bin/cosmic bench/<suite>.tl` on `bench/harness.tl`, and by nothing else.

A new module (cosmic.git) needed all four, in three layouts and three
runners. A bench ran by no test rots: a renamed function breaks it, and
nothing says so until someone times it.

## decision

A test, a fuzz property, an example and a bench are one thing: a body that
the runner calls with its inputs. What differs is what the runner gives the
body and what it keeps of the call.

1. **Benches live beside their module, as functions of its test file.** A
   top-level `local function bench_<name>(b: Bench.B)` in a `*_test.tl`
   file is a bench. Its body runs its operation `b.n` times. Work before
   the loop is setup; `b.reset()` starts the clock again after it.
   `b.bytes` set to the bytes one operation reads gives a rate. The runner
   finds `bench_*` as it finds `test_*`: by the name alone.
2. **`cosmic test` runs each bench once.** In a plain run, a bench is a
   test with `b.n` 1: it fails when it raises, its verdict stands like a
   test's, and its time is in the run's list of longest tests. A bench
   cannot rot unnoticed, and a slow one is seen.
3. **`cosmic test --bench [selector...]` times them.** It is `cosmic test`
   in a mode, not a verb of its own: it selects only the `bench_*`
   functions of what the selectors name, runs each whatever verdict
   stands, one worker at a time, and in each worker runs the body once as
   a test and then, with coverage off, doubles `b.n` until a batch takes
   the target time (`--target-ms`, 50) and times `--rounds` batches (5).
   It prints the fastest and the median ns per operation of each, or one
   JSON object per bench with `--json`. Selectors, the sandbox, policies,
   deadlines and reruns are `cosmic test`'s.
4. **Fuzz properties are functions by prefix too.** A top-level
   `local function fuzz_<name>(): Fuzz.Target` returns
   [`Fuzz.target`] of the property; the runner checks it with
   [`Fuzz.run_target`] in the test's directory. `cosmic test` checks it
   at a few inputs (`FUZZ_ITERS`, 64), and `cosmic test --fuzz-deep`
   draws many (10000, for at most `FUZZ_SECONDS` 120 each), whatever
   verdict stands; the weekly `fuzz.yml` runs it. The target is a class
   that only cosmic.fuzz makes and reads, since the checker narrows a
   class with `is` only inside its module and refuses a cast from the
   `any` a worker is returned. A generator is a value
   ([`Fuzz.Property`]'s `gen`) another body can draw from:
   [`Fuzz.inputs`] returns a property's corpus and the first `n` inputs
   a run draws, so a bench of the same file times the module on them. A fuzz failure
   is kept in the corpus, so it is a test and a bench input both. A test
   that builds its properties in a loop still calls [`Fuzz.run`];
   `--fuzz-deep` takes every test of a `*_fuzz_test.tl` file for it.
5. **Examples keep their own file.** An example is documentation that
   `cosmic docs` shows and a built program carries; it stays the record
   `Example` that `<module>_example.tl` returns, run as a test as it is
   today. A function of a test file is not shipped, so an `example_*`
   prefix there would show nothing.
6. **`cosmic test --bench --against <old-binary>` compares two builds.**
   Each binary runs its own copy of the chosen test files, copied out of
   the checkout with the tree modules they require and the testdata/ they
   name, so each side's `require("cosmic.*")` is its own built-in
   standard library. The two alternate, a child each a round, for
   `--rounds` rounds (20, at least 6), and [`Bench.compare`] pairs the
   rounds into a ratio, a 95% band and a verdict. `--binary` names the
   new side, this program by default.
7. **One results store.** A bench run keeps its timings in `results.db`
   in the build directory ([`build.results`]), keyed by the binary's
   sha256: `rounds`, `arms` and `bench_runs`, a row for each timed batch,
   and `--against` keeps both sides, so a run keeps a history of each
   bench. It is not `build.db`: that is a cache, which a change of its
   schema makes again from nothing, and history must outlive it. The
   agent evals keep their rounds in tables of the same shape
   (eval/runs.tl), with what only an eval has in tables of its own.

The layout a module follows, then: `<module>.tl`; `<module>_test.tl` for
its `test_*`, `bench_*` and `fuzz_*`; `<module>_<topic>_test.tl` where one
file grows too long or needs another policy (a bench of a large fixture,
say); `<module>_example.tl` for what the docs show.

## rejected alternatives

- **A file kind per companion** (`<module>_bench.tl` as `_example.tl` is):
  a new kind is a new glob in the build's kinds, a new tail and a new
  runner path, and it keeps four layouts where one does.
- **A bench as a script that returns its entry point**, as `bench/` had:
  `cosmic test` cannot run a script, so nothing runs it until someone
  times it.
- **A `cosmic bench` verb**: a verb is a spec, a help page and a
  dispatch entry for what one flag of `cosmic test` says, and the two
  would drift.
- **Timing in a plain `cosmic test`**: a run of the whole suite runs many
  workers at once, under coverage, and its times are noise. A bench is
  timed only when asked, one worker at a time, with coverage off for the
  timed batches.

## consequences

- `bench/` empties into the modules' test files, and `bench/harness.tl`'s
  statistics move to [`cosmic.bench`], where a project's own benches use
  them too. Its `--against` is `cosmic test --bench --against`
  ([`build/test_against.tl`]).
- A bench that needs a fixture declares it with the module's
  [`Test.policy`], like any test; a bench can no longer read the tree
  without saying so.
- A bench's setup runs on every plain `cosmic test` once its verdict moves,
  so a costly fixture belongs in the body before `b.reset()`, not at the
  file's top level, where it would cost every test of the file.
- Comparing two binaries needs both to have `cosmic test --bench`.

[`Bench.compare`]: ../../cosmic/bench.tl
[`build.results`]: ../../build/results.tl
[`build/test_against.tl`]: ../../build/test_against.tl
[`cosmic.bench`]: ../../cosmic/bench.tl
[`Fuzz.inputs`]: ../../cosmic/fuzz.tl
[`Fuzz.Property`]: ../../cosmic/fuzz.tl
[`Fuzz.run_target`]: ../../cosmic/fuzz.tl
[`Fuzz.run`]: ../../cosmic/fuzz.tl
[`Fuzz.target`]: ../../cosmic/fuzz.tl
[`Test.policy`]: ../../cosmic/test.tl
