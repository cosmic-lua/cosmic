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

## Refinement pass, 2026-08-20 (settles directory shape, trigger, wiring)

Spiked against the current tree:

1. **Directory shape — settled.** `cosmic.fs.write`/`make_dirs` (both
   public, `cosmic/fs/file.tl:48`, `cosmic/fs/dir.tl:116`) are the
   write primitives. One file per regression, raw bytes (not
   `cosmic.literal` — the payload is arbitrary binary, exactly what
   `driver.bytes()` produces, and literal's grammar cannot represent
   arbitrary byte strings as a scalar). Path:
   `_fuzz/testdata/<opts.name>/<sha256-of-input>` — content-addressed,
   so re-triggering the same crash never writes a second file and two
   sessions finding the same bug never conflict. `_fuzz/testdata/`
   sits under the existing `testdata/` convention (AGENTS.md: "never
   embedded"), so it needs no new exemption anywhere in the graph
   (strip floor, embed generator, lint).
2. **Write trigger — settled.** Never on an ordinary run, including
   CI: writing a new regression file is a deliberate act, gated behind
   `FUZZ_SAVE=1` in the environment, read the same way
   `env_integer`/`env.get` already read `FUZZ_SEED`/`FUZZ_ITERS`
   (`driver.tl`'s existing `env_integer` helper). Unset or any other
   value: no write, current behavior unchanged. This keeps every
   Acceptance command elsewhere in the tree side-effect-free against
   the committed tree by construction — nothing about this item's own
   Acceptance may ever set `FUZZ_SAVE`.
3. **Isolated-child wiring — settled.** Replay is NOT a separate
   spawn. `run_in_process` (driver.tl, the function every isolated
   child and `run_unisolated` both call) gains a step before its
   iteration loop: list `_fuzz/testdata/<opts.name>/*`
   (`cosmic.fs.walk` or a directory listing — exact call TBD next
   pass), and for each file, run `opts.check` on its bytes directly
   (no `gen`, no Recorder — the input is already concrete). A
   replay failure reuses `failure()`'s shape with `iteration` replaced
   by the filename in the message (exact format TBD: `failure()`
   currently takes an `integer` iteration, so either it grows a
   string-iteration overload or replay gets its own formatter — this
   is the one piece the next pass must design, not spike, since it is
   a pure API-shape decision with no tree-fact to measure). A replay
   input that CRASHES surfaces through the exact same
   `isolate()`/`spawn_isolated()` signal-handling path child 5 built,
   because it runs inside the same child process, before the generated
   loop — no changes needed to `isolate()` itself, only to what
   `run_in_process` does first.

## Refinement pass, 2026-08-20 #2 (settles message shape, protections, listing)

Spiked against the current tree; each decision the previous pass left
open now has one answer, so nothing here is TBD.

4. **Replay's failure message — settled: its own formatter, not a
   grown `failure()`.** A replay has no `seed`, no `iteration` number
   and no `draws` count — inventing zeros to reuse `failure()`'s six
   slots is a lie the reader has no way to tell from truth. The new
   sibling formatter (its own local in `driver.tl`, one caller — the
   replay path) is:

       "<name>: corpus=<basename> input(base64)=<b64>: <detail>"

   where `<basename>` is the file's basename under
   `_fuzz/testdata/<opts.name>/` (the sha256 hex — 64 chars, unique
   per input, enough to `find _fuzz/testdata -name <hex>`), `<b64>` is
   `codec.encode_base64(bytes)` on the file's contents (keeps the
   message self-contained — no need to open the file to see what
   failed), and `<detail>` is the property's returned message or the
   `pcall` throw, exactly like `failure()`'s tail. `failure()` itself
   is UNCHANGED — its `integer` iteration signature stays, and every
   existing `driver_test.tl` substring assertion (`iteration=1`,
   `iteration=5`, etc.) keeps meaning what it means. `corpus=` /
   `iteration=` are the two distinguishing tokens; grepping one never
   false-hits the other, and Acceptance test #2 below asserts that
   directly.

5. **Wall-clock and VM-budget protection for replay — settled: yes,
   the same protections as a generated iteration.** Each `opts.check`
   call on a corpus entry is wrapped in `arm_budget(budget)` /
   `disarm_budget()` (`driver.tl:53`, `:64`) — a stored regression
   that stops terminating fails with `budget=%d exceeded`, not a hung
   run. The wall-clock timeout is inherited for free: replay executes
   inside the isolated child, before the generated loop, and
   `spawn_isolated`'s `timeout_ms` (`driver.tl:198`,
   `DEFAULT_TIMEOUT_MS = 30000`) caps the whole child. This is why
   replay lives in `run_in_process` and not before `isolate()` — both
   protections come for free from being in the child.

6. **Directory listing and missing-corpus behavior — settled.** Two
   `cosmic.fs` calls (both public: `cosmic/fs/init.tl:241`, `:305`):
   - `fs.is_dir(corpus_dir)` — silent boolean probe, no error, no
     stat leak. When it returns false (the common case: most
     properties have no corpus yet), replay skips to the generated
     loop with no further fs calls and no log line.
   - `fs.find(corpus_dir, {recursive = false, sorted = true})` —
     one flat directory of leaf files, sorted so replay order is
     deterministic across runs and across sessions. A `nil, err`
     return here (unreadable dir when `is_dir` said yes — e.g.
     `EACCES`) surfaces AS a failure via the same
     `pcall`-wrapping the loop already does elsewhere — reported
     through the isolated child's stderr, which `isolate()` already
     forwards.
   - Corpus root is `fs.join(fs.dirname(arg[0]), "testdata",
     opts.name)`, so it colocates with the test file for any project
     using `cosmic.fuzz` and needs no repo-specific constant. An env
     override `FUZZ_CORPUS_DIR` — read via the same `env.get` pattern
     — points the driver at a caller-supplied root instead; this is
     what the new Acceptance tests set to `TEST_TMPDIR` and what a
     future non-`_fuzz/` fuzz test would set to its own testdata dir.

7. **Where the FUZZ_SAVE write happens — settled.** Inside
   `run_in_process`, on the failing return path, AFTER shrinking has
   produced `minimized_input` and BEFORE constructing the `failure()`
   message. Two lines added to the existing failing branch: compute
   `hash.sha256_hex(minimized_input)`, and if
   `env_integer("FUZZ_SAVE", 0) == 1`,
   `fs.make_dirs(corpus_dir)` then
   `fs.write(fs.join(corpus_dir, hex), minimized_input)`. The write
   is content-addressed, so a repeat failure overwrites its own file
   with identical bytes — idempotent by construction. A write error
   (disk full, EROFS) is ignored: the failure message the property
   just produced is more important than the FUZZ_SAVE side effect,
   and a caller that cared would notice the file absent.

8. **Crash regressions in corpus — deferred, not this item.** A
   corpus entry that C-crashes when replayed enters the isolated
   child's crash path (`isolate()` sees `r.signal`), and today's
   `bisect_crash` narrows the failing ITERATION count — which for a
   corpus-only crash is meaningless (the child always crashes,
   whatever `iters` says, because it never reaches the generated
   loop). This cut preserves the misattribution: the report will
   still say `iteration=<N>` with a fresh generated input, wrong for
   corpus but no more silent than today's status quo. Corpus-crash
   attribution — probing "does it still crash with corpus disabled"
   and, if yes, bisecting the corpus file list instead of iterations
   — belongs to a separate child item under 3I1j7yQA and is called
   out as a non-goal below.

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
  existing generated-iteration bisection, which will misattribute it
  to iteration=1 with a fresh input. Fixing that requires teaching
  `isolate()`/`bisect_crash` about the corpus/generated split. Filed
  as its own follow-up under 3I1j7yQA (the epic).
- No timing/quota on the corpus loop separate from the generated loop.
  Per-file budget is the same VM-instruction budget the generated loop
  uses (#5 above); the wall-clock cap is the child's `timeout_ms` as a
  whole. A corpus of ten thousand files taking longer than 30s is a
  size finding for a separate item, not a bug in this one.

## Acceptance

Every command below is run from the repository root and must print the
literal verdict line quoted after it. Every command uses only
`FUZZ_SEED`, `FUZZ_ITERS`, `FUZZ_CORPUS_DIR` and `TEST_TMPDIR`;
`FUZZ_SAVE` is set only by tests INSIDE `driver_test.tl` — never on the
command line — so no Acceptance run mutates the committed tree.

1. **Build gates the diff (fmt, check, example, lint, coverage).**

       bin/cosmic --make ci

   Verdict line ends `ci: PASS`.

2. **Replay is dark on a missing corpus dir; existing driver tests
   still pass.** The new tests for corpus-replay behavior live in
   `_fuzz/driver_test.tl`; when no `_fuzz/testdata/<name>/` exists
   for a property, `run_unisolated` returns exactly what it does
   today (same true/false, same message shape — the `iteration=` /
   `seed=` / `draws=` tokens still present, `corpus=` absent).

       bin/cosmic --make test _fuzz/driver_test.tl

   Verdict line ends `test: PASS`.

3. **All six existing `*_fuzz_test.tl` properties still pass with no
   committed corpus.** Nothing about corpus infrastructure changes
   the pass/fail of properties whose corpus directory does not
   exist.

       bin/cosmic --make test _fuzz

   Verdict line ends `test: PASS`.

4. **A corpus entry that fails is reported with `corpus=<basename>`
   and its base64 bytes.** Covered by a new
   `test_corpus_entry_failure_is_reported` in
   `_fuzz/driver_test.tl`: set `FUZZ_CORPUS_DIR` to `TEST_TMPDIR`,
   write a bytes file under `<TEST_TMPDIR>/<opts.name>/<sha>` whose
   contents fail the property, run `run_unisolated`, assert the
   returned message CONTAINS `corpus=<sha>` and CONTAINS
   `input(base64)=` and does NOT contain `iteration=` /
   `seed=` / `draws=`. Runs as part of #2.

5. **Corpus entries are checked before generated iterations, in
   sorted basename order.** Covered by
   `test_corpus_runs_before_generated_in_sorted_order`: two corpus
   files whose names sort deterministically, the first failing and
   the second passing; a property whose generated input would ALSO
   fail. The returned message must name the first-sorted corpus
   file (not the second, not a generated iteration). Runs as part
   of #2.

6. **`FUZZ_SAVE=1` writes a content-addressed file; unset does
   not.** Covered by `test_fuzz_save_writes_content_addressed`:
   with `FUZZ_CORPUS_DIR` pointed at `TEST_TMPDIR` and `FUZZ_SAVE`
   set to `"1"`, run a property that fails; assert exactly one file
   exists at `<TEST_TMPDIR>/<name>/<hash.sha256_hex(minimized)>`
   and its bytes equal the minimized input. Then a second run with
   `FUZZ_SAVE` UNSET (both true unset and set to `"0"`) writes no
   new file. `restore()` unsets `FUZZ_SAVE` at teardown. Runs as
   part of #2.

7. **The write is idempotent under re-triggering the same failure.**
   Covered by `test_fuzz_save_is_idempotent`: run the same failing
   property twice with `FUZZ_SAVE=1`; assert exactly one file
   present in the corpus dir afterwards and its bytes unchanged.
   Runs as part of #2.

## Enablement

Ready. Children 1–5 landed. Every open question from the first pass
is now settled:

- Replay message shape: its own formatter (#4).
- Wall-clock and VM budget for replay: same as generated (#5).
- Directory listing / missing-dir behavior / corpus root: `fs.is_dir`
  guard + non-recursive sorted `fs.find`, rooted at
  `fs.dirname(arg[0])/testdata/<name>` with a `FUZZ_CORPUS_DIR`
  override for tests (#6).
- Where the FUZZ_SAVE write happens: inside `run_in_process` on the
  failing path, after shrinking, silent on write errors (#7).

Every Acceptance command reads its verdict line from a single tool
invocation — no piped exit statuses — as AGENTS.md requires. The item
adds one `hash` import to `driver.tl` and no new module dependencies
otherwise; every call it uses (`fs.is_dir`, `fs.find`, `fs.make_dirs`,
`fs.write`, `fs.dirname`, `fs.join`, `hash.sha256_hex`,
`codec.encode_base64`, `env.get`, `env_integer`) is already public
API that the driver either uses today or is one line away from.

Deferred as a separate child item under 3I1j7yQA (the epic): corpus
crash-attribution — teaching `isolate()`/`bisect_crash` to distinguish
a crash induced by a corpus file from one induced by iteration N. See
Non-goals for the exact split.
