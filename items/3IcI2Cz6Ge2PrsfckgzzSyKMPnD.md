## Problem

Two comments in the `_make/clean` pair went stale when the `kept_detail`
rework landed (PR #1552, merged 2026-08-30). Both verified against
`origin/main` today.

**1. `_make/clean.tl:39-41` documents a fixed bug instead of the
contract.** The doc comment on `kept_detail` reads:

```
--- The summary detail's "kept ..." clause, naming only what was
--- actually kept -- the unconditional "kept the verified bootstrap"
--- used to run even when the only thing kept was a worktree.
```

`git show origin/main:_make/clean.tl | sed -n '36,46p'`

The second sentence is history — the behaviour it describes no longer
exists — which the `docs-style` skill forbids (state what the code is
for, no history). The timeless form says the same thing as a contract:
a tree that never had a bootstrap is never told one survived.

**2. `_make/clean_test.tl:4-8` asserts something the file contradicts
five lines later.** The header says:

```
-- This file asserts clean's behavior through the spawned binary, not
-- through `require`, so the module under test is a real dependency the
-- require graph cannot see -- the declared read above is what puts it
-- in this rule's make prerequisite and the record's content key.
```

but `git show origin/main:_make/clean_test.tl | grep -n 'require('`
shows line 20: `local clean = require("_make.clean")`. The rework added
five in-process tests, so the file now drives the module BOTH ways and
the header's "not through `require`" is false.

That also puts the `--- reads: _make/clean.tl` declaration on line 2 in
question: #1554 added it precisely because the require graph could not
see the module, and the graph can now see it directly. Whether the
declaration is genuinely redundant is NOT established here — it needs
checking against the built `o/project.mk`'s `deps__make/clean_test`
fact before removal, since a declared read that is also a require edge
may or may not be a no-op in that closure. Do not delete it on this
item's word alone.

## Non-goals

No behaviour change to `clean` or to `kept_detail`. No test added or
removed.
