## Change

Corrected after a build bounce (2026-08-30) that falsified the first
spec's root cause with hard evidence — trust this version. The false
green reproduces exactly as first measured (mutate `_make/clean.tl`,
rebuild, `--make test _make/clean_test.tl` green with identical wall
time while the direct compiled run goes red). But the test rule in
`embed/cosmic.mk` ALREADY carries `$$(deps_$$*)` as a prerequisite
(verbatim since the file's origin commit 7b9f0749), and
`_cli/build/work.tl`'s `do_record` keys its content-addressed skip on
the same deps list. The real gap: `deps_<stem>` is the REQUIRE-edge
closure (`_make/deps.tl`), and `_make/clean_test.tl` never requires
`_make.clean` — it validates behavior by SPAWNING the freshly built
binary — so neither the make prerequisite nor the record key sees
`clean.lua`, and the recipe re-fires but `do_record` short-circuits on
an unchanged key (only `.got` is touched; `.test.in`/`.test.time`
stay stale). A deliberate design decision (the "d17 rule" noted
inline) declines to name the project binary as a test prerequisite —
that wall stands.

The fix uses the EXISTING declared-reads mechanism (`--- reads:`
comments, consumed by `_make/imports.tl`'s `reads_scan` and wired
through `_make/graph.tl` into `deps_<stem>`/the record key; live
precedents: `_build/coldbuild_test.tl`, `_perf/skew_test.tl`):

1. Add `--- reads: _make/clean.tl` to `_make/clean_test.tl`, with a
   one-line comment stating why (the test asserts clean's behavior
   through the spawned binary, so the module under test is a real
   dependency the require graph cannot see).
2. Audit the sibling subprocess-driving `_make/*_test.tl` files
   (grep for the spawn pattern; the bounce named `build_test.tl`,
   `fixtures_test.tl`, `fixpoint_test.tl`) and add the analogous
   `--- reads:` for the module(s) whose behavior each asserts. Name
   MODULES under test, never the binary (the d17 wall).
3. PROOF, the same pair the bounce ran: with the annotation, the
   clean.tl mutation must flip the NARROW `--make test
   _make/clean_test.tl` red (fresh record run), and restoring goes
   green. Paste both.
4. Regression coverage: if an existing `_make`/`_build` test seam can
   assert that project.mk's `deps__make/clean_test` includes the
   annotated read, add that one assertion; if no seam fits, say so.

Full `--make ci` PASS before pushing.

## Non-goals

No embed/cosmic.mk changes (the rule is correct). No `_make/deps.tl`
closure-semantics changes. No binary-as-prerequisite (the d17 wall).
No cache weakening.
