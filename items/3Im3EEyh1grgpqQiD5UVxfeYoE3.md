## Goal

Settle whether `_make/testrun.tl`'s `testrun_dep` (embedded via
`embed/cosmic.mk:188` as a universal prerequisite of every test's
`.got` rule) already invalidates every spawned-binary test's cached
record when the tree's embedded engine changes — before any more
per-file engine-dependency declarations are added.

## Evidence

A fresh-context review of cosmic-lua/cosmic#1636 (board item
`3IkoLdmJvBjUx5sJXF9wKJbQ00X`, «wKJb_Q00X») reproduced the item's own
prescribed repro (edit `_make/check.tl`, rebuild, rerun) with the PR's
guard in `_make/graph.tl` disabled (the `built[#built+1] =
project.out_dir("bin/cosmic")` line inside `project_mk`, gated by a new
`exercises_the_engine(path)` helper matching `^_make/` or `^_cli/`), and
found `_make/fixtures_test.tl.test.got` still got a fresh mtime — the
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
2. If yes: is #1636's fix (see Evidence — a positional, by-directory
   `deps_<stem>` addition in `_make/graph.tl`, not a per-file `---
   reads:` header) redundant, harmless-but-unnecessary, or does it
   serve a distinct purpose worth keeping anyway?
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

## Resolution (settled by clean reproduction against #1636's ACTUAL current head)

**A first pass at this item (research handover, reviewed under session
`review-f041b4ef-4ede-491c-a382-d75779b08e0b-Vxfe`) got REQUEST-CHANGES:
its reproduction hand-added a per-file `--- reads: o/bin/cosmic` header
line to `_make/fixtures_test.tl`, reproducing an EARLIER, abandoned
commit of #1636 (`83cf3042`) rather than the PR's actual current head
(`0b13276e`, matching the SHA recorded in `wKJb_Q00X`'s own `verdict:`
field). The current PR does not touch `_make/fixtures_test.tl`'s
`reads:` line at all — it adds `o/bin/cosmic` as a positional
`deps_<stem>` entry in `_make/graph.tl`'s `project_mk`, for every test
file under `_make/**` or `_cli/**` (gated by a new
`exercises_the_engine(path)` helper), specifically BECAUSE a `reads:`
header requires its named path to already exist when `project.mk` is
generated — which fails on a cold checkout, before `o/bin/cosmic`
exists. This section corrects that error and re-verifies against the
real diff.**

**Answer to Q1: NO — unchanged from the reviewer's finding.**
`testrun_dep` alone does NOT invalidate a spawned-binary test's actual
re-execution on an engine rebuild. It only ever forces make to
re-invoke the test's `record` recipe LINE (a scheduling effect, via a
moved `.got` mtime); whether the test's process is actually spawned
again is decided separately, one layer down, by
`_cli/build/work.tl`'s `do_record` — the D18 content-key skip — whose
`inkey` computation (`for i = 2, #argv do ... end`, explicitly skipping
`argv[1]`, the driver path `testrun_dep` is what moves) is structurally
blind to it.

**Mechanism, corrected against the actual diff:** `_make/graph.tl`'s
`project_mk` builds each test's `deps_<stem>` list (line ~198-206 in
the current PR). #1636 adds one conditional entry to that list:
```lua
if f.kind == "test" and exercises_the_engine(f.path) then
  built[#built + 1] = project.out_dir("bin/cosmic")
end
```
This is the SAME channel the original research pass traced for a
`reads:`-declared path — `deps_<stem>` is emitted via `assign("deps_"
.. stem, built)`, consumed by the recipe line's `--deps $(deps_$*)`,
and folded byte-for-byte into `do_record`'s hashed `inputs`
(`_cli/build/work.tl:346-350`). Whether an entry reaches `built` via a
per-file `--- reads:` header (parsed by `_make/imports.tl`'s
`reads_of_file`) or via this positional append in `project_mk` is
immaterial to the mechanism traced in Q1 — both feed the same list,
which is the only channel giving `do_record`'s content-key skip any
sensitivity to the engine's bytes. The reviewer's own mutation test
(disabling the `built[#built+1] = project.out_dir("bin/cosmic")` line
directly, not a `reads:` token) is therefore the correct test of the
actual mechanism, and it reproduces the original staleness bug exactly
as the item's evidence describes — confirming Q1's answer against the
real diff, not just the abandoned first commit.

**Answer to Q2:** #1636's actual fix is **NOT redundant — it is
necessary**, for the same reason as before: `testrun_dep` structurally
cannot give `do_record`'s content key any visibility into the engine's
bytes; only a `deps_<stem>` entry can, and #1636 is how one gets there
for every `_make/**`/`_cli/**` test file. #1636 should be KEPT.

**Revised guidance for `1XDh_5npx` (the ~20-file audit) — THIS
SUPERSEDES THE FIRST PASS'S "unblock as scoped" RECOMMENDATION:**
#1636's fix is positional and by-directory: it already covers EVERY
test file under `_make/**` or `_cli/**` that has `kind == "test"`, not
just `_make/fixtures_test.tl`. Every file `1XDh_5npx`'s own evidence
names as needing an audit — `_make/build_test.tl`,
`_make/artifact_test.tl`, `_make/check_test.tl`, `_cli/args_test.tl`,
`_cli/fence_test.tl`, `_cli/build/recipe_test.tl`, and the rest of the
"roughly 20 other files" so long as they sit under `_make/` or `_cli/`
— will be covered automatically once #1636 merges, with NO per-file
work needed. Only the files `1XDh_5npx` names OUTSIDE `_make/`/`_cli/`
— `_tool/testrun_test.tl`, `_tool/lint_test.tl`, and any other
`_tool/*_test.tl` that spawns the tree's `cosmic` binary the same way —
fall outside `exercises_the_engine`'s `^_make/` / `^_cli/` match and
still need their own fix (most likely: widen
`exercises_the_engine`'s pattern to include `^_tool/`, if `_tool/`
tests spawn the binary for the same reason, rather than adding
per-file declarations — a single-line, same-shape follow-up to #1636,
not a 20-file audit). `1XDh_5npx` should be RE-SCOPED to just the
`_tool/**` remainder (auditing which `_tool/*_test.tl` files actually
spawn the tree's binary, and whether widening
`exercises_the_engine` is the right fix for them), not unblocked to
proceed on its original ~20-file plan.

**One correction worth carrying into #1636's own rework (out of this
item's scope to make, per its Non-goals):** none beyond what the
reviewer already found — #1636's actual diff and its commit message
are consistent with each other and with this item's corrected
Resolution above. (The first pass's proposed "commit message
correction" does not apply: it was based on the abandoned first
commit, not the PR's current state.)

**Confound behind the review's "fixes itself" reading (Q3, unchanged):**
the review's mutation test was accurate — `.got`'s mtime does move on
every engine rebuild, with or without #1636's fix, because
`testrun_dep` is genuinely universal — but mtime-freshness of `.got` is
not the same fact as the test having re-executed. Checking `.in`/`.time`
(or a duration that must differ on a real rerun) resolves the
ambiguity, as both this item's reproduction and the reviewing pass's
independent reproduction did.
