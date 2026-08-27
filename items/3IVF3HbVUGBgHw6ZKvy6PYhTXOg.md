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

## Correction — 2026-08-27 (session e532d9f6)

**The framing above is half wrong, and the measurement that corrects it
makes the finding larger.** "The guard does not do what its docstring
says" is true; "so the guard is the defect" does not follow. Measured
on the pinned bootstrap `2026-08-27-555873e`:

**The binary carries `_perf` twice, and both copies shadow the tree.**

```
o/3p/cosmos/zip -sf o/bootstrap/cosmic | grep -cE '^\s+_perf/'      # 30 compiled modules at the zip root
o/3p/cosmos/zip -sf o/bootstrap/cosmic | grep -cE '\.tl/_perf/'     # 30 sources on the include path
```

The `.tl/` copy is what the type checker reads, which is the failure
3IUBNQZZ hit. The zip-root `_perf/*.lua` copy is what a RUNTIME
`require` reads, and that one is the bigger fact. A bare script run
from a tree root under that binary:

```lua
local compare = require("_perf.compare")
print(debug.getinfo(compare.format, "S").source)
```

```
$ o/bootstrap/cosmic /tmp/probe_resolve.lua
format source: @/zip/_perf/compare.lua
```

Run from the worktree whose `_perf/compare.tl` widens
`compare.format` to three parameters, the three-argument call
nonetheless **succeeds against the one-parameter embedded copy** — Lua
discards the extra arguments — printing the ordinary summary line. So
the tree's module was not merely out-voted; it was never loaded, and
nothing said so.

**Therefore the guard is FAITHFUL, not broken.** It reproduces on the
PR exactly the resolution the release lane has at runtime, which is
what a guard is for. What is wrong is its DOCSTRING — "`_perf.*`
resolves from the tree at cwd" is false in both contexts measured here
— and its remedy advice, which sends the reader to a tolerant map view
and a capability probe. That pattern is right for reaching a *cosmic*
API newer than the pin; it is not a remedy for a *sibling `_perf`*
signature change, where the honest reading is "the pinned binary is
checking you against its own copy of the module you just changed."

**And the consequence reaches past the guard.** `release.yml`'s
compare step runs the tree's `_perf/run.tl` under the PREVIOUS release
binary. `run.tl` itself is passed by path, so the tree's copy executes
— but every `require("_perf.harness")`, `require("_perf.compare")` and
`require("_perf.bench.*")` inside it resolves to that previous
release's embedded copy, by the measurement above. Whether the lane is
therefore measuring the tree's scenarios or the previous release's is
the question this item now turns on, and it is NOT yet established.

## What this item must settle, in order

1. **The release-lane picture, measured**: for `release.yml`'s compare
   step, which `_perf` files actually execute — tree or embed — for
   the harness, for `compare`, and for each bench module; whether a
   bench module added in the tree is seen or silently skipped; and
   whether `run.tl` enumerates benches by filesystem scan or by a
   require list. Until this is answered the fix cannot be chosen,
   because the two candidate fixes serve different defects.
2. **What governs precedence**, quoted from the searcher: whether
   `/zip` beating cwd is deliberate and configurable, or incidental.
3. **Then the fix**, which is one of:
   - the resolution is correct and only the guard's docstring and
     failure message are wrong — a documentation change, and
     `_perf` signature changes genuinely stage behind a release and a
     pin bump, a cost that should be written down where a session
     planning a `_perf` change will read it;
   - or the release lane is measuring the wrong code and the
     precedence is the defect, in which case the fix is in the
     searcher or the lane, not in the guard.

Route 3a leaves 3IUBNQZZ needing a two-PR-plus-a-release dance;
route 3b unblocks it in one PR. They are not the same item, so this
one stops at the evidence and the choice.
