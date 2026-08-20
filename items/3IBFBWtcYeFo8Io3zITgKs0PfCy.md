## Goal

G5, via the cosmic.fuzz epic (3I1j7yQA, "Children" item 6): corpus
persistence under `testdata/`, so a failing input becomes a permanent
regression the suite replays on every subsequent run instead of a seed
number a human has to remember to turn into a test by hand.

## Problem, measured 2026-08-20

`_fuzz/driver.tl` (215 lines, `wc -l < _fuzz/driver.tl`) reports a
minimized failing input in its message
(`"<name>: seed=%d iteration=%d input(base64)=%s draws=%d: %s"`,
`failure()` at line 119) but writes nothing to disk. Today the only
record of a found bug is that message plus the convention that a human
transcribes it into a regression test — the epic's own spec cites #1161
doing this manually, five times. `driver_test.tl` (312 lines,
`wc -l < _fuzz/driver_test.tl`) has no corpus-reading code, and no
`_fuzz/testdata/` directory exists yet.

`run()` (driver.tl:307) now always isolates (landed as child 5,
3IAXDNwC): every property call re-execs the compiled test file as a
child with `FUZZ_ISOLATE` naming the one property to actually run
(`isolate()`, `spawn_isolated()`). Corpus replay has to happen INSIDE
that isolated child, on the same `run_in_process` call the parent's
child spawned — not as a separate pass in the parent — or a corpus
entry that itself crashes would never get the isolation/attribution
child 5 just built.

## Change

Two edits to one module — `_fuzz/driver.tl` — plus new tests in
`_fuzz/driver_test.tl`. No new files in `_fuzz/testdata/` are committed
by this item; no existing `*_fuzz_test.tl` property changes.

### 1. Corpus root and its knob

Add a private helper `corpus_dir(opts: Options): string` that returns
`env.get("FUZZ_CORPUS_DIR")` when set (tests point it at
`TEST_TMPDIR`), otherwise `fs.join(fs.dirname(arg[0]), "testdata",
opts.name)` — which colocates the corpus with the fuzz test file and
works for any project using `cosmic.fuzz`, not just this repo. Path
math via public `cosmic.fs.dirname` / `cosmic.fs.join`
(`cosmic/fs/init.tl:452`, `:462`).

### 2. `run_in_process` runs the corpus first

Before the existing `for i = 1, iters` loop, add a corpus pass:

- `fs.is_dir(corpus_dir(opts))` — silent boolean probe, no error, no
  stat leak. False (the common case: most properties have no corpus
  yet) skips the pass entirely, no fs calls beyond the probe, no log.
- `fs.find(corpus_dir(opts), {recursive = false, sorted = true})` —
  one flat directory of leaf files, sorted so replay order is
  deterministic across runs and across sessions. A `nil, err` here
  (unreadable dir after `is_dir` said yes — e.g. `EACCES`) returns
  from `run_in_process` as a plain failure via the new sibling
  formatter — surfaced through the isolated child's stderr like
  every other failure the loop produces.
- For each file in sorted order: `fs.read(path)` for the bytes;
  `arm_budget(budget)` around `pcall(opts.check, bytes)`;
  `disarm_budget()`. A held check moves to the next file. A false
  return, a throw, or a `BUDGET_MESSAGE` throw returns false with
  the new replay formatter (below), reporting the basename and the
  base64 of the file's contents. No shrinking (the input is already
  concrete — that's the whole point of a corpus entry).

Wall-clock protection is inherited: `spawn_isolated`'s `timeout_ms`
(`driver.tl:198`, `DEFAULT_TIMEOUT_MS = 30000`) caps the whole child,
corpus pass and generated loop together.

### 3. Replay's failure formatter — its own local, not a grown `failure()`

A replay has no `seed`, no `iteration` number and no `draws` count —
inventing zeros to reuse `failure()`'s six slots is a lie the reader
has no way to tell from truth. New local formatter in `driver.tl`, one
caller (the replay path):

    "<name>: corpus=<basename> input(base64)=<b64>: <detail>"

where `<basename>` is the file's basename under the corpus dir (the
sha256 hex — 64 chars, enough to `find _fuzz/testdata -name <hex>`),
`<b64>` is `codec.encode_base64(bytes)` on the file's contents (keeps
the message self-contained), and `<detail>` mirrors `failure()`'s tail
(`what` — a property message, or `"threw: ..."`, or
`("budget=%d exceeded"):format(budget)`).

`failure()` itself is UNCHANGED — its `integer` iteration signature
stays, and every existing `driver_test.tl` substring assertion
(`iteration=1`, `iteration=5`, etc.) keeps meaning what it means.
`corpus=` / `iteration=` are the two distinguishing tokens; grepping
one never false-hits the other, and Acceptance test #4 asserts that
directly.

### 4. FUZZ_SAVE write path

Inside `run_in_process`, on the FAILING-generated-iteration branch
(the existing block that computes `minimized_input` at line 171),
after shrinking and before constructing the `failure()` message:

- Compute `hex = hash.sha256_hex(minimized_input)`.
- If `env_integer("FUZZ_SAVE", 0) == 1`:
  - `fs.make_dirs(corpus_dir(opts))` (idempotent — makes intermediate
    dirs too, `cosmic/fs/dir.tl:116`).
  - `fs.write(fs.join(corpus_dir(opts), hex), minimized_input)`.
- Write errors are ignored (no `check`, no throw): the property's
  failure message is the load-bearing output, and a caller who cared
  about the file would notice it absent. Two callers finding the same
  bug write identical bytes to the same path, so the write is
  idempotent by construction — no lock, no rename dance.

`FUZZ_SAVE` is read via the existing `env_integer` helper
(`driver.tl:99`), the same way `FUZZ_SEED` / `FUZZ_ITERS` are read —
so any value other than `1` (unset, `"0"`, `"true"`, garbage) is a
no-op. No default-on path, ever.

### 5. New imports in `driver.tl`

`hash` (for `sha256_hex`) and `fs` (for `dirname`, `join`, `is_dir`,
`find`, `read`, `write`, `make_dirs`) join the module's existing
imports. `codec` is already imported (line 2). Total: two new require
lines.

## Non-goals

- No change to `failure()`'s signature or its message shape for a
  GENERATED-input failure. Only replay's report is new ground, and it
  uses its own separate formatter.
- No automatic corpus pruning or deduplication in this item; if the
  corpus grows unbounded that is a separate finding. Content-addressed
  filenames already dedupe by BYTES, so the growth surface is "distinct
  minimized bugs", not "re-triggers of the same one".
- Not a rewrite of the six existing `*_fuzz_test.tl` properties. This
  item adds the corpus infrastructure; no existing property changes
  and no committed `_fuzz/testdata/` files are added by this item.
- No default-on write path. `FUZZ_SAVE` stays opt-in, and CI's
  `--make ci` / `--make test _fuzz` runs never set it — verified by
  Acceptance #6 asserting no write with `FUZZ_SAVE` unset.
- **Not this item — crash-regression attribution for corpus entries.**
  A corpus entry that C-crashes when replayed reports through the
  existing generated-iteration bisection (`isolate()` / `bisect_crash`,
  `driver.tl:245`, `:216`), which will misattribute it to `iteration=1`
  with a fresh input — meaningless for a corpus-only crash where the
  child always crashes regardless of `iters`. Fixing that requires
  teaching `isolate()` to probe "does this still crash with corpus
  disabled" and, if yes, bisect the corpus file list instead of
  iteration counts. Filed as its own follow-up under 3I1j7yQA (the
  epic). This item's tests all use `run_unisolated` (in-process, no
  crash path) so the deferral does not gate its Acceptance.
- No timing/quota on the corpus loop separate from the generated loop.
  Per-file budget is the same VM-instruction budget the generated loop
  uses; the wall-clock cap is the child's `timeout_ms` as a whole. A
  corpus of ten thousand files taking longer than 30s is a size
  finding for a separate item, not a bug in this one.

## Acceptance

Every command below is run from the repository root and must print the
literal verdict line quoted after it. Every command uses only
`FUZZ_SEED`, `FUZZ_ITERS`, `FUZZ_CORPUS_DIR` and `TEST_TMPDIR`;
`FUZZ_SAVE` is set only by tests INSIDE `driver_test.tl` — never on
the command line — so no Acceptance run mutates the committed tree.

1. **The full gate holds (fmt, check, example, lint, coverage).**

       bin/cosmic --make ci

   Verdict line ends `ci: PASS`.

2. **All six existing `*_fuzz_test.tl` properties still pass with no
   committed corpus.** Nothing about the corpus infrastructure
   changes the pass/fail of properties whose corpus directory does
   not exist.

       bin/cosmic --make test _fuzz

   Verdict line ends `test: PASS`.

3. **`driver_test.tl` (including the new corpus-behavior tests, #4–#7
   below) passes.**

       bin/cosmic --make test _fuzz/driver_test.tl

   Verdict line ends `test: PASS`.

4. **A corpus entry that fails is reported with `corpus=<basename>`
   and its base64 bytes; the generated-iteration tokens are absent.**
   Covered by a new `test_corpus_entry_failure_is_reported` in
   `_fuzz/driver_test.tl`: set `FUZZ_CORPUS_DIR` to a per-test
   directory under `TEST_TMPDIR`, write a bytes file under
   `<dir>/<opts.name>/<sha>` whose contents fail the property, run
   `run_unisolated`, assert the returned message CONTAINS
   `corpus=<sha>` and CONTAINS `input(base64)=` and does NOT contain
   any of `iteration=`, `seed=`, `draws=`. Runs as part of #3.

5. **Corpus entries are checked before generated iterations, in
   sorted basename order.** Covered by
   `test_corpus_runs_before_generated_in_sorted_order` in
   `_fuzz/driver_test.tl`: two corpus files whose basenames sort
   deterministically, the first failing and the second passing, plus
   a property whose generated inputs would ALSO fail. The returned
   message must name the first-sorted corpus file (assert
   `corpus=<first-sha>` present, `corpus=<second-sha>` absent,
   `iteration=` absent). Runs as part of #3.

6. **`FUZZ_SAVE=1` writes a content-addressed file; unset does not.**
   Covered by `test_fuzz_save_writes_content_addressed` in
   `_fuzz/driver_test.tl`: with `FUZZ_CORPUS_DIR` pointed at
   `TEST_TMPDIR` and `FUZZ_SAVE` set to `"1"`, run a property that
   fails; assert exactly one file exists under
   `<TEST_TMPDIR>/<name>/` and its basename equals
   `hash.sha256_hex(bytes_at_that_path)` and its bytes equal the
   minimized input the failure message reports. Then, with
   `FUZZ_SAVE` UNSET (both truly unset and set to `"0"`), the same
   failing property writes no NEW file. `restore()` unsets
   `FUZZ_SAVE` at teardown. Runs as part of #3.

7. **The write is idempotent under re-triggering the same failure.**
   Covered by `test_fuzz_save_is_idempotent` in `_fuzz/driver_test.tl`:
   run the same failing property twice with `FUZZ_SAVE=1`; assert
   exactly one file present in the corpus dir afterwards and its
   bytes unchanged between the two runs. Runs as part of #3.

## Enablement

Ready. Children 1–5 landed. Every open question from the first pass
is now settled in Change §§1–5, and each answers a single decision
point rather than a range:

- Replay message shape: its own formatter, `corpus=<basename>` /
  `input(base64)=<b64>` / `<detail>` (Change §3).
- Wall-clock and VM budget for replay: same as generated —
  `arm_budget`/`disarm_budget` around each `opts.check`, inherited
  child `timeout_ms` (Change §2).
- Directory listing and missing-dir behavior and corpus root:
  `fs.is_dir` guard + non-recursive sorted `fs.find`, rooted at
  `fs.dirname(arg[0])/testdata/<name>` with a `FUZZ_CORPUS_DIR`
  override for tests (Change §§1–2).
- Where the FUZZ_SAVE write happens: inside `run_in_process` on the
  failing-generated branch after shrinking, silent on write errors
  (Change §4).

Every Acceptance command reads its verdict line from a single tool
invocation — no piped exit statuses — as AGENTS.md requires. Every
call the change uses (`fs.is_dir`, `fs.find`, `fs.make_dirs`,
`fs.write`, `fs.read`, `fs.dirname`, `fs.join`, `hash.sha256_hex`,
`codec.encode_base64`, `env.get`, `env_integer`) is already public
API that the driver either uses today or is one line away from.

Deferred as a separate child item under 3I1j7yQA: corpus
crash-attribution (Non-goals bullet 5). Non-blocking here because this
item's tests all use `run_unisolated` and therefore never enter the
crash-bisection path the deferral concerns.
