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

## Resolution (settled by clean reproduction)

**Answer to Q1: NO.** `testrun_dep` alone does NOT invalidate a
spawned-binary test's actual re-execution on an engine rebuild. It
only ever forces make to re-invoke the test's `record` recipe LINE
(a scheduling effect, via a moved `.got` mtime); whether the test's
process is actually spawned again is decided separately, one layer
down, by `_cli/build/work.tl`'s `do_record` — the D18 content-key
skip — and that skip is structurally blind to `testrun_dep`.

**Mechanism, read from source (no PR/graph.tl "guard" exists — #1636's
entire diff is one line, the `reads: o/bin/cosmic` token in
`_make/fixtures_test.tl`'s header; "disabling" it means reverting that
token):**

- `embed/cosmic.mk`'s `.got` rule
  (`$(O)/%.tl.test.got: $(O)/%.lua $(O)/.stamp/record $$(deps_$$*)
  $(testrun_dep)`) makes `testrun_dep` (`o/.testrun/cosmic`) a bare
  make PREREQUISITE of every test, universally — confirmed: it is
  identical text for every test rule, spawned-binary or not.
- The recipe line is `record $(basename $@) $(testrun) $< --deps
  $(deps_$*)` — `$(testrun_dep)` is a prerequisite but is NEVER placed
  after `--deps`, so it never reaches `do_record`'s `args`.
- `do_record` (`_cli/build/work.tl:314-385`) computes its content key
  (`inkey`) from a `label` and `inputs` built by
  `for i = 2, #argv do ... end` over `argv = {$(testrun), $<}` — this
  loop starts at `i = 2`, i.e. it explicitly SKIPS `argv[1]`, the
  `$(testrun)` driver path itself (comment: "The label is the argv
  MINUS the driver's absolute path"). Only `deps` (the tokens after
  `--deps`, i.e. `deps_$*`) and `$<` (source) feed the hash.
- So `testrun_dep`'s mtime move (which fires on every engine rebuild,
  repo-wide) gets the recipe line invoked, but `do_record`'s key sees
  no change (nothing it hashes moved) when a test's `deps_$*` does not
  itself name the engine — and takes the skip path:
  `fs.touch(out .. ".got")` and `return 0`, WITHOUT calling
  `testrun.run(argv, out)` at all. `.in`/`.time`/`.out` are left
  completely untouched; only `.got`'s mtime moves.
- A declared `--- reads: o/bin/cosmic` line is different in kind: it
  joins `deps_<stem>` (`_make/graph.tl:148-157`, via
  `imports.reads_of_file`), which IS passed after `--deps` on the
  recipe line, which IS folded byte-for-byte into `do_record`'s
  `inputs` (`_cli/build/work.tl:346-350`). Only this path gives the
  content key any sensitivity to the embedded engine's bytes at all.

**Clean reproduction (cosmic-lua/cosmic @ main, commit `4e2f3fc4`,
built from a fresh clone via `bin/cosmic --make fetch && bin/cosmic
--make build`):**

| step | `_make/fixtures_test.tl` reads: | `o/bin/cosmic` | `fixtures_test.tl.test.got` mtime | `fixtures_test.tl.test.{in,time}` | reported duration | `string_test.tl.test.got` mtime | `string_test.tl.test.{in,time}` |
|---|---|---|---|---|---|---|---|
| 1. baseline `--make test` | no `o/bin/cosmic` | built | fresh (record ran) | written | 7668ms | fresh (record ran) | written, 12ms |
| 2. no-op rerun | same | unchanged | **unchanged**, no `record` line printed at all (make-level cache hit) | unchanged | 7668ms | unchanged | unchanged, 12ms |
| 3. edit `_make/check.tl` (comment only), `--make build` | same | **bytes/mtime changed** (D17 replace-if-changed) | — | — | — | — | — |
| 4. rerun `--make test` after step 3 | same (no `o/bin/cosmic` yet) | unchanged since step 3 | **fresh** (`record` line printed) | **UNCHANGED** (same mtime/content as step 1) | **7668ms — byte-identical to step 1** | **fresh** (`record` line printed) | **UNCHANGED**, still 12ms |
| 5. add `o/bin/cosmic` to `reads:` (matches #1636 exactly), edit `_make/check.tl` again, `--make build` | **now declares `o/bin/cosmic`** | bytes/mtime changed again | — | — | — | — | — |
| 6. rerun `--make test` after step 5 | same | unchanged since step 5 | fresh | **fresh, NEW content** | **6400ms — genuinely different, real rerun** | fresh (`record` line printed, as always) | **still UNCHANGED**, still 12ms |

Step 4 is the crux: `.got` got a fresh mtime (matching the review's
observation and technically satisfying "the record no longer replays
as PASS-unchanged at the make-scheduling level"), but the test did NOT
actually re-execute — `.in`/`.time` prove it via `do_record`'s own
on-disk trail, independent of any inference about "wall time
suspiciously matching." Step 6, with the fix applied, shows the same
file genuinely re-running (new duration, `.in`/`.time` both rewritten)
on the exact same kind of engine edit. `cosmic/string_test.tl` (the
PR's designated control, still undeclared throughout) gets a fresh
`.got` mtime on every engine rebuild in every trial — exactly as
`testrun_dep` predicts, since it is a universal prerequisite — but its
`.in`/`.time` never move: it is correctly skip-restamped every time,
never actually re-run, which is the desired behavior for a pure unit
test whose behavior does not depend on the embedded engine.

**Answer to Q2 (posed under "if yes", but decisive here as the
practical question):** the per-file `reads: o/bin/cosmic` declaration
added by #1636 is **NOT redundant — it is necessary**, and is the
correct, minimal fix. It is the only channel (`deps_<stem>` →
`--deps` → `do_record`'s `inputs`) that gives the content-key skip any
visibility into the embedded engine's bytes; `testrun_dep` structurally
cannot, because `do_record`'s `inkey` loop starts at `argv[2]`,
deliberately excluding the driver path `testrun_dep` is what moves.
#1636 should be KEPT, not dropped or reworked away. `1XDh_5npx` (the
~20-file audit) rests on a correct premise and should be UNBLOCKED to
proceed as scoped, now that this item has settled the question it was
waiting on.

**One correction worth carrying into #1636's own rework (out of this
item's scope to make, per its Non-goals):** #1636's commit message
explains the fix as "declaring `o/bin/cosmic` ... makes the binary a
prerequisite of the test's record ... and D17's replace-if-changed
gives it a fresh mtime ... so the test re-runs" — that is the
*testrun_dep* mechanism, which step 4 above proves is NOT what makes
the fix work (mtime alone did not force a rerun). The load-bearing
mechanism is `deps_<stem>` feeding `do_record`'s D18 content key, not
mtime scheduling. The fix is right; its stated rationale is not.

**Confound behind the review's "fixes itself" reading (Q3, for
completeness even though Q1's answer is NO in the sense that matters):**
the review's mutation test was accurate as far as it looked —
`.got`'s mtime does move on every engine rebuild, with or without the
per-file declaration, because `testrun_dep` is genuinely universal —
but mtime-freshness of `.got` is not the same fact as the test having
re-executed. The review did not check `.in`/`.time` (or the reported
duration) against the pre-rebuild run, so it read a scheduling
side-effect common to every test as if it were the specific,
per-file re-execution #1636 is about. Checking the `.in`/`.time` pair
(or a duration that must differ on a real rerun) resolves the
ambiguity, as this item's reproduction did.
