## Goal

Settle whether `_make/testrun.tl`'s `testrun_dep` (embedded via
`embed/cosmic.mk:188` as a universal prerequisite of every test's
`.got` rule) already invalidates every spawned-binary test's cached
record when the tree's embedded engine changes — before any more
per-file `reads: o/bin/cosmic` declarations are added.

## Evidence

A fresh-context review of cosmic-lua/cosmic#1636 (board item
`3IkoLdmJvBjUx5sJXF9wKJbQ00X`, «wKJb_Q00X») reproduced the item's own
prescribed repro (edit `_make/check.tl`, rebuild, rerun) with the PR's
new `reads: o/bin/cosmic` guard in `_make/graph.tl` disabled, and found
`_make/fixtures_test.tl.test.got` still got a fresh mtime — the
staleness this item's evidence reported "fixes itself" with the fix
turned off. The review also found the PR description's own designated
control (`cosmic/string_test.tl`, claimed NOT to re-run) getting a
fresh mtime on every trial regardless.

Suspected mechanism: `_make/testrun.tl:58-64`'s `build()` re-embeds the
project's root payload onto the just-rebuilt `cosmic` binary during
every `prepare_stage` (`_make/init.tl:180-193`), so
`o/.testrun/cosmic` — via D17 replace-if-changed — already gets a
fresh mtime exactly when the embedded engine changes, for every test
in the repo via `testrun_dep`, not only ones that spawn the binary.
This predates both items (PR #931) and is not mentioned in either
item's evidence.

## Change

Read `_make/testrun.tl`, `_make/init.tl`, `embed/cosmic.mk`, and
`_make/graph.tl` together and determine, with a clean reproduction (not
just re-reading the review's claims):

1. Does `testrun_dep` alone already invalidate a spawned-binary test's
   `.got` record on any engine rebuild, repo-wide, today?
2. If yes: is the per-file `reads: o/bin/cosmic` declaration added by
   #1636 (and proposed for ~20 more files by board item `1XDh_5npx`)
   redundant, harmless-but-unnecessary, or does it serve a distinct
   purpose (e.g. narrower invalidation, clearer intent) worth keeping
   anyway?
3. If no (testrun_dep does NOT already cover this): explain why the
   review's mutation test (guard disabled, staleness bug still "fixed
   itself") happened anyway — is there a different confound?

Record the finding as this item's resolution. If the premise is
confirmed false (testrun_dep already handles it), #1636 should be
reworked to either drop its now-redundant change or explain the
distinct value it adds, and `1XDh_5npx` (the ~20-file audit) should be
re-scoped or dropped once the premise is settled.

## Non-goals

- Not itself a code change to `_make/testrun.tl` or `_make/graph.tl`.
- Not a rework of #1636 — that happens after this question resolves,
  on #1636's own item.
