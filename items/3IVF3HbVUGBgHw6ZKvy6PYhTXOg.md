## Evidence

`_perf/skew_test.tl` type-checks every non-test `_perf/**` file under
the pinned bootstrap binary. Its docstring claims "`_perf.*` resolves
from the tree at cwd." It does not: the cosmic binary embeds its own
`_perf` sources at `.tl/_perf/*.tl`, and that include path SHADOWS the
tree. Measured in an empty directory holding only a `probe.tl` that
requires `_perf.compare`, with no `_perf` tree present at all:

```
$ o/bootstrap/cosmic --check types probe.tl
Type check passed: probe.tl
```

So the guard checks the tree's `_perf/gate.tl` and `_perf/run.tl`
against the PINNED RELEASE's `_perf/compare.tl`, not the tree's.

**The consequence is general: any change to a `_perf` module's
exported signature that a sibling `_perf` module calls is unlandable
in one PR.** Found by 3IUBNQZZ, which widens `compare.format` with two
optional parameters and is called from both siblings:

```
_perf/gate.tl:128:23: error: wrong number of arguments (given 3, expects 1)
_perf/run.tl:358:23: error: wrong number of arguments (given 3, expects 1)
```

Causation proven both ways: `git stash` then
`bin/cosmic --make test _perf/skew_test.tl` ends `test: PASS`;
unstashed it fails. `_perf/compare.tl` has not been touched since the
skew guard landed (`ccd246ab`, #1427; last compare.tl change
`ef963bab`, #1419), so 3IUBNQZZ is the FIRST change to a `_perf`
module's exported signature after the guard and no precedent exists.

**The guard's error message is misleading in this case.** It says "a
`_perf` file reaches an API the pinned bootstrap does not declare" and
directs the reader to the map-view / capability-probe pattern — correct
for a *cosmic* API newer than the pin, actively wrong for a sibling
`_perf` module, where the honest reading is "you changed a `_perf`
signature and the guard is comparing you against the pinned release's
copy of it." Applying the prescribed pattern to one's own sibling
module would add unjustifiable casts.

## The decision this needs

Either the guard should place the tree AHEAD of the binary's embedded
`.tl/_perf` — which would make it match its own docstring and unblock
ordinary `_perf` refactoring — or `_perf` signature changes are
genuinely meant to stage behind a release and pin bump, in the same
shape as CLAUDE.md's cold-build rule, in which case the docstring and
the error message must say so and the cost should be recorded. Until
one is chosen, 3IUBNQZZ (and every future `_perf` signature change) is
blocked on an undocumented two-PR-plus-a-release dance.
