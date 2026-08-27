## Goal

G4 — zero-config gates that do not wedge: a converging build that
fails under the tree's own `o/bin/cosmic` names the escape
(`rm o/bin/cosmic` to retry from the pin) instead of printing only
the compile error, so neither wedge face costs a session an hour of
misdiagnosis again.

## Evidence (both faces hit and escaped by hand, 2026-08-27, this
session; full narrative on the item)

- Face 1: a red generation-2 leaves `o/bin/cosmic` as generation-1's
  product; every later run — `bin/cosmic` prefers it — re-enters the
  poisoned binary, whose generation-1 build fails compiling the tree
  under its embedded checker, and the loop never reaches the stage
  that would replace it.
- Face 2: after `git checkout` to another branch, the standing
  `o/bin/cosmic` (built from branch A, embedding A's checker) fails
  generation-1 on branch B's tree at exactly the files A's diff had
  to fix.
- Both faces reduce to one detectable condition in
  `_make/converge.tl:to_the_tree` (297 lines, 203 headroom): the
  child `--make build` fails while `was_us` holds (the running
  binary IS `o/bin/cosmic`, `converge.tl:210`). The pin path
  (`was_us` false) needs no hint: a failing pinned build is a real
  tree error and the pin cannot be stale.
- The failure paths are the two returns after `child.run` at
  `converge.tl:219-225` ("the converging build failed"), plus the
  no-artifact return; all three currently print no remedy.

## Change

In `_make/converge.tl`, `to_the_tree`: when the converging build
fails (either failed-run return) and `was_us` is true, append one
sentence to the refusal: the build ran under the tree's own
`o/bin/cosmic`, which may not match this tree; remove it
(`rm o/bin/cosmic`) and re-run to rebuild from the pin. Keep the
existing first line and verdict detail unchanged (verdict-line
format is frozen); the hint is an addition, never a rewording.

Tests in `_make/converge_test.tl` (234 lines, 266 headroom), in its
existing fixture style: a failing build under `was_us` carries the
hint; a failing build under the pin path (running binary is not the
artifact) does not.

## Non-goals

No auto-deletion of `o/bin/cosmic` — a failed build's artifact is
evidence, and removal is the session's call once named. No build-graph
change (why a failed parallel build can leave a half-consistent
binary is real but separate; this slice makes the state diagnosable,
not impossible). No change to the fixpoint cap, the probe, or the
re-exec flow. Frozen: the `make:`-prefixed refusal shapes' first
lines and the verdict details ("build failed", "no artifact").

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _make/converge_test.tl` passes, including
  a new test whose name contains `wedge` or `hint`.
- `grep -c "rm o/bin/cosmic" _make/converge.tl` → 1.

## Enablement

none needed — one function, its test file, and both faces' evidence
measured in-session.
