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
`testdata/` directory exists yet under `_fuzz/`.

`run()` (driver.tl:123) now always isolates (landed as child 5,
3IAXDNwC): every property call re-execs the compiled test file as a
child with `FUZZ_ISOLATE` naming the one property to actually run.
Corpus replay has to happen INSIDE that isolated child, on the same
`run()` call the parent spawned — not as a separate pass in the
parent — or a corpus entry that itself crashes would never get the
isolation/attribution child 5 just built.

## Open design questions (why this is not ready yet)

This item stays in `plan`; a follow-up refinement pass must settle,
with measurements/spikes like child 5's, before it can move to
`ready`:

1. **Directory shape.** Go's convention is
   `testdata/fuzz/<FuzzFunc>/<hash>`, one file per regression, content
   plus a `go test fuzz v1` header. cosmic's equivalent needs a path
   under `_fuzz/testdata/` (never embedded, per AGENTS.md's `testdata/`
   convention) keyed by `opts.name` — exact layout (one file per
   property vs. one per failure, filename scheme, file format: raw
   bytes vs. `cosmic.literal`) is undecided.
2. **Write trigger and safety.** `run()` must not write to the
   committed tree on an ordinary `--make ci` run (Acceptance commands
   elsewhere in this repo are required to be side-effect-free against
   the committed tree) — writing a new regression file is a
   deliberate, opt-in act, not a side effect of every fuzz run. Needs
   an explicit mechanism (an env var? a `--make fuzz --save` verb?)
   and a decision on whether CI itself ever writes one.
3. **Replay ordering and cost.** "Replayed before generated inputs"
   (the epic's own child-6 line) means every property pays a corpus
   read on every run, inside the isolated child (see above) — needs a
   measurement of the cost at realistic corpus sizes, and a decision on
   whether a replay failure reports through the same `failure()` shape
   or a distinct one (it has no seed/iteration to report — it has a
   filename).
4. **Interaction with minimization (child 3, landed) and isolation
   (child 5, landed).** A corpus entry that crashes needs the SAME
   bisection/attribution path child 5 built for generated inputs; a
   corpus entry that merely fails needs no bisection (there is only
   one input, not a sequence). The isolated child currently receives
   `FUZZ_SEED`/`FUZZ_ITERS`/`FUZZ_ISOLATE` only (spawn_isolated,
   driver.tl) — a corpus-replay child needs a way to name which
   fixture(s) to replay, or replay could happen unconditionally
   inside every isolated child before its generated loop starts.

## Non-goals (provisional — restate once the above settles)

- No change to `failure()`'s message shape for a GENERATED-input
  failure — only a replay failure's report shape is new ground.
- No automatic corpus pruning or deduplication in this item; if the
  corpus grows unbounded that is a separate finding.
- Not a rewrite of the six existing `*_fuzz_test.tl` properties beyond
  what wiring corpus replay into `run()` requires.

## Acceptance

not yet written — depends on the design questions above.

## Enablement

blocked on nothing landed-wise (children 1–5 are all in), but blocked
on ITS OWN refinement: the directory shape, write trigger, and
isolated-child wiring above must be spiked and measured, the same way
child 5's spec settled argv/Result/granularity before it was ready.
