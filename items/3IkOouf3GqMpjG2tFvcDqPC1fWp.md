## Evidence

Reported by the builder of cosmic-lua/cosmic#1607 (hold marker, on the
`board` branch, built under the pinned cosmic release via `bin/cosmic`).
A runner-mode test file (D29 shape: top-level `local function test_*`
defined, never called) is nondeterministically green under `--make ci`:

- When the test stage's compile seam (which appends the generated
  calls) ran first, `check` reports the file "already proved by their
  strict compile" and passes.
- When `check` type-checks the raw file cold — reproduced by running
  `bin/cosmic --make test _work/githold_test.tl` on one file and then
  `bin/cosmic --make ci` — it fails with `warning: unused function
  test_...` for every case (`_work/githold_test.tl:21:1` in the
  builder's run, since warnings are errors).

Every existing `_work/*_test.tl` self-calls its cases, which sidesteps
the gap; #1607's new file was made to self-call for the same reason,
against AGENTS.md's "write new files in runner mode" rule. The
"already proved" cache accepts the seam's compile as proof of a file the
raw checker rejects — the same class as `3IU4umVT` (compile seam misses
`--make check`), reappearing through the proof cache rather than the
check verb itself. Whether the fault is in the pinned release's checker
(a pin bump fixes it) or in the check stage's proof-cache key is the
first thing to measure: re-run the reproduction above on cosmic `main`
with `o/bin/cosmic` (tree checker) and with `bin/cosmic` (pinned).

## Change

Refine into a Change once measured. Expected shape: the check stage's
"already proved" cache keys on the exact source the seam compiled (the
generated tail included), or the raw check applies the seam to a
runner-mode file exactly as `--make test` does — one mechanism, so the
order of `test` and `check` can never change `check`'s verdict. Add a
test in `_make/` that runs `test` on a runner-mode fixture and then
`check` on the same tree and asserts the same verdict both orders.
