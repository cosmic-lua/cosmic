## Goal

G5, via the cosmic.fuzz epic (3I1j7yQA, "Children" item 6): corpus
persistence under `testdata/`, so a failing input becomes a permanent
regression the suite replays on every subsequent run instead of a seed
number a human has to remember to turn into a test by hand.

## Problem, measured 2026-08-20

`_fuzz/driver.tl` (215 lines, `wc -l < _fuzz/driver.tl`) reports a
minimized failing input in its message
(`"<name>: seed=%d iteration=%d input(base64)=%s draws=%d: %s"`,
`failure()` at line 99) but writes nothing to disk. Today the only
record of a found bug is that message plus the convention that a human
transcribes it into a regression test — the epic's own spec cites #1161
doing this manually, five times. `driver_test.tl` (312 lines,
`wc -l < _fuzz/driver_test.tl`) has no corpus-reading code, and no
`_fuzz/testdata/` directory exists yet.

`run()` (driver.tl:123) now always isolates (landed as child 5,
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

## Still open (next pass)

- The `failure()` string-vs-integer iteration question above.
- Whether a replay runs under the VM budget hook / wall-clock timeout
  the same as a generated iteration (almost certainly yes, for the
  same hang-protection reason, but not yet stated as a decision).
- Exact `cosmic.fs` calls for listing a directory's entries (walk vs.
  a dedicated list function) and their error-shape on a missing
  `testdata/<name>/` directory (must be silent — most properties will
  have no corpus yet).

## Non-goals (provisional — restate once the above settles)

- No change to `failure()`'s message shape for a GENERATED-input
  failure — only a replay failure's report shape is new ground.
- No automatic corpus pruning or deduplication in this item; if the
  corpus grows unbounded that is a separate finding.
- Not a rewrite of the six existing `*_fuzz_test.tl` properties beyond
  what wiring corpus replay into `run_in_process` requires.
- No default-on write path: `FUZZ_SAVE` stays opt-in, and CI's
  `--make ci`/`--make test _fuzz` runs never set it.

## Acceptance

not yet written — depends on the `failure()` iteration-shape decision
above.

## Enablement

blocked on nothing landed-wise (children 1–5 are all in). Directory
shape, trigger and isolated-child wiring are now settled by spike; the
`failure()` string-vs-integer shape is a design decision, not a
measurement, and is what the next refinement pass must resolve before
this clears the ready bar.
