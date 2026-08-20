## Goal

G5, via the cosmic.fuzz epic (3I1j7yQA, "Children" item 5): crash
isolation via `cosmic.child`, so a C-layer fault (a segfault or hang
inside a binding a property calls into — `re`, `json`, `compress`,
`zip`) is attributed to the input that caused it instead of killing
the whole fuzz run with no attribution.

## Context, measured 2026-08-20 at `origin/main`

- `_fuzz/driver.tl` is 215 lines (285 lines of headroom under the
  500-line cap). Its `run` function already has a per-check VM
  instruction budget (child 4, landed as 3I7PFJE7): `arm_budget`/
  `disarm_budget` wrap `pcall(opts.check, input)` and turn a runaway
  Lua loop into a caught, attributed failure. That mechanism catches
  a Lua-level hang; it does NOT catch a C-layer crash (a segfault, an
  abort, an OOM kill) inside a binding `opts.check` or `opts.gen`
  calls into, because a crashed process never returns to the `pcall`
  at all — there is nothing to catch.
- `cosmic/child/init.tl`'s public surface (474 lines) is `start`
  (`Handle`, `stop`/`wait`/`try_wait`/`read`) and the one-shot `run(argv,
  opts): Result | nil, string` — both spawn an argv, not a Lua
  closure. Isolating one `driver.run` iteration therefore cannot pass
  `opts.gen`/`opts.check` across the process boundary directly; it
  needs some way to re-invoke a single fuzz property, for one
  recorded draw sequence, as a fresh OS process, and read that
  process's exit status (and a timeout) as pass/fail/crashed.
- `_fuzz/sse_fuzz_test.tl`'s hand-rolled bound is ALREADY gone —
  landed by child 4 (3I7PFJE7's spec deleted `Drained.is_bounded` in
  favor of the driver's instruction budget). The epic prose above
  citing it as still-open is stale; this item's own refinement pass
  should correct that line in 3I1j7yQA's spec when it lands.

## The open design question this item's refinement must settle

How does an isolated iteration get re-invoked as its own process? Two
shapes were visible from this pass and neither is chosen yet:

1. **Re-exec the test file.** `cosmic.child.run` spawns
   `{cosmic_binary, "--make", "test", "<this _fuzz_test.tl path>"}` with
   `FUZZ_SEED`/`FUZZ_ITERS` narrowed to the one failing iteration, and
   the driver treats a non-zero exit or a `cosmic.child` timeout as a
   crash, distinct from an ordinary `check` failure. Cheap to wire (no
   new binary target), but re-running the whole file re-executes every
   property in it up to that iteration, not just the one under
   isolation.
2. **A dedicated single-shot entry point.** `_fuzz/driver.tl` grows a
   mode that takes a serialized draw sequence (via `source.replay`,
   already landed) and re-runs exactly one property's `gen`+`check`
   against it, so the re-exec'd process does only that. More precise,
   more plumbing: draws need a wire format (existing `Draw` record is
   already `{kind, lo, hi, ivalue, fvalue}`, so JSON via `cosmic.json`
   is a plausible fit), and the driver needs a CLI entry cosmic's
   dispatcher can reach.

Whichever shape wins needs to answer, as Acceptance commands: what a
crashed child's failure message looks like (still the same
`failure()` shape other driver failures use, or a distinct one naming
"crashed" explicitly), whether isolation is opt-in per property or
the driver's default for every iteration (the latter has a real
per-iteration process-spawn cost worth measuring against the
existing `_perf` fuzz-adjacent scenarios, if any exist, before it
becomes the default), and how a timeout is chosen (a fixed default,
an `Options` field, or reuse of the existing instruction-budget
knob's spirit at wall-clock granularity since a subprocess has no VM
hook to attach).

## Non-goals (carried from the epic)

- no corpus persistence (`testdata/`, item 6) and no discard
  accounting (item 7) — separate children.
- no change to the six `*_fuzz_test.tl` generator bodies beyond
  whatever the chosen isolation mechanism requires them to opt into
  (should be zero, if isolation lives entirely in `driver.tl`).
- no `cosmic.fuzz` publishing move (item 8, still blocked on the
  placement decision the epic's own spec has not yet settled).

## Why this is `plan`, not `ready`

The two re-invocation shapes above are a real design decision the
ready bar (`decompose.md`) forbids leaving hidden in Acceptance
prose — "acceptance by vibes" / "hidden decisions" both apply until
one shape is picked. This capture exists so the container's
decomposition isn't lost between refinement passes; driving it to
ready is a dedicated refine pass's job, ideally opening with a spike
against option 1 (cheapest to prototype) to see whether a crashed
child's `cosmic.child.run` `Result` already carries enough signal
(exit code, captured stderr) before committing to option 2's extra
plumbing.
