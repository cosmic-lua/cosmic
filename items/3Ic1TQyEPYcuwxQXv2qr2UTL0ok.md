## Change

Reproduced twice independently (builder and reviewer of PR #1541,
2026-08-30): with a live mutation in `_make/clean.tl` and the mutated
module confirmed embedded in the rebuilt binary, the narrow
`bin/cosmic --make test _make/clean_test.tl` reported an IDENTICAL
green (same counts, same wall time) — a stale cached result — while
directly running the compiled `o/_make/clean_test.lua` went red.
Root cause as measured: the test's cached outcome
(`.test.time`/`.test.out` beside the compiled test) was not
invalidated when a DEPENDENCY of the test changed; the test file
itself was unchanged, so its cache replayed. The build already
computes each source's transitive import closure
(`o/project.mk`'s `srcdeps_<stem>` vars; rules live in the committed
`embed/cosmic.mk` — constant rules, generated facts).

The change: make the test-run rule's prerequisites include the
test's transitive dependency closure so a changed import re-runs the
test. Work in this order and STOP AND REPORT if the shape breaks:
1. REPRODUCE first, exactly as measured (mutate clean.tl, rebuild,
   narrow test green, direct run red). Paste both outputs.
2. Locate the rule that produces/consults `.test.time`/`.test.out`
   (read `embed/cosmic.mk` and whatever in `_make/`/`_tool/` drives
   `--make test`); identify why srcdeps are absent from its prereqs.
3. Fix minimally — prefer wiring the existing `srcdeps_<stem>` vars
   into the existing rule over any new mechanism. Remember
   `embed/cosmic.mk` is byte-identical for every project and no rule
   is ever generated: the fix must hold that invariant.
4. Show the SAME reproduction now goes red through the narrow path,
   then restore and show green. That before/after pair is the proof;
   also add whatever regression test the harness can carry (a
   `_make`/`_build` test asserting the rule's prereqs include the
   deps var, if the fixture seams allow; if no seam can express it,
   say so rather than forcing one).
Full `--make ci` PASS before pushing; mind the fixpoint/convergence
notes in AGENTS.md (a make-rule change is toolchain-facing — if the
converged gate passes but you suspect a cold-build interaction, run
the fixtures test `_make/fixtures_test.tl` too and say what you saw).

## Non-goals

No change to test discovery, runner mode, or coverage; no per-project
generated rules; no weakening of the cache (correct invalidation, not
cache removal).
