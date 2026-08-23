## Evidence

Confirmed while reviewing PR #1347 (board item `3IKSi0JN`, accepted
2026-08-23). That item's `## Acceptance` carried the bullet:

> the seeded run passes and prints the seed it used, so a failure is
> replayable — run it twice and read the same seed line.

No properties file can satisfy it. `_fuzz/driver.tl`'s
`run_in_process` returns its summary as the SECOND value —
`return true, string.format("%s: %d iterations, seed=%d", ...)` — and
every properties file consumes it as `check.truthy(ok, msg)`, which
reads `msg` only when `ok` is false. So a GREEN fuzz run prints
nothing at all:

```
$ FUZZ_SEED=20260823 FUZZ_ITERS=200 bin/cosmic --make test _fuzz/json_fuzz_test.tl
✓ _fuzz/json_fuzz_test.tl (5 test functions)
test: PASS (1 file)                  # no seed line, and none available
```

True of all seven properties files, not just literal's. The builder
hit the bullet, could not satisfy it without editing `_fuzz/driver.tl`
— which the same spec walls off as a Non-goal — read it as the spec
describing the harness wrongly, and left the driver alone. That was
the right call and the PR was accepted, so this cost one paragraph of
PR prose rather than a bounce. The next spec that copies the bullet
may not be so lucky.

Two things this could be, and the choice is the refiner's:

1. **the spec was wrong** — the replayability the bullet protects is
   already delivered by the FAILURE path (`seed=N iteration=N
   input(base64)=… draws=N`), so a future fuzz spec should assert on a
   deliberately-failing run, not a green one. The countermeasure is
   then a worked fuzz-slice acceptance somewhere a refiner will find
   it.
2. **the harness is wrong** — a green run that says nothing about
   which seed it just spent is a gap in `_fuzz/driver.tl`, and the fix
   is one line printing the summary it already builds. That touches
   the shared driver and every properties file's output, so it is its
   own slice with its own spec.

Not both. Whoever refines this picks one and closes the other out.
