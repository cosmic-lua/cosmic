## Problem

`cosmic/format/init_test.tl` is a test file with **zero** `test_*`
function definitions: 425 lines whose body is top-level
`assert_format(...)` / `assert_idempotent(...)` calls (51 at column 1,
plus more inside three top-level `do ... end` blocks). Measured on
origin/main c9b0b31f:

```
grep -c 'local function test_' cosmic/format/init_test.tl   -> 0
wc -l < cosmic/format/init_test.tl                          -> 425
grep -cE '^assert_(format|idempotent)\(' cosmic/format/init_test.tl -> 51
```

Because it has no `test_*` functions it has no self-call lines, so the
runner-mode migration batches correctly never touch it — batch 3
(3IU6AsZC) has it in scope and leaves it alone, which is why its `find`
names 28 files while only 27 are modified.

The problem is what happens at the container's exit. 3IOCdooE states
its exit test as "every `*_test.tl` classifies `runner` or `empty`
under `_tool/discover`". This file will classify `empty` and satisfy
that test — while its assertions run as a bare chunk with no per-test
identity, no continue-past-failure (the first failed assert ends the
file), and no reachability from `--filter`. That is precisely what D29
("tests run because they are defined") exists to prevent, so the
container would declare its outcome met on a file that most defeats it.

The decision this needs, and does not yet have: is `empty` an
acceptable terminal state for a file that is manifestly a test? If not,
the change is to give this file `test_*` functions grouping its
assertions — but how to group 425 lines of format fixtures (one case
per fixture, per fixture-family, or per `do` block) is unsettled, and
the case count and the coverage row both move with the answer. Refine
by choosing the grouping and naming it here before this is pullable.

A sweep for other `*_test.tl` with zero `test_*` definitions has NOT
been run; this file was found incidentally while reviewing batch 3. Run
that sweep during refinement — the item may be larger than one file.

## Non-goals

No assertion changes: whatever grouping is chosen, the file must keep
testing exactly what it tests. No change to `_tool/discover.tl`'s
classification rules as a way of dodging the question.
