The doc-citation lint verifies a doc's quoted line against the CITED
file, but the lint stage's incremental cache keys only on the DOC's own
content — so a change that edits the cited source and not the doc gets
a stale cached PASS locally, and the failure first appears in CI's cold
run. Observed 2026-08-26 on PR #1406 (board 3ISJKfRg): the diff removed
two casts that docs/design/casts.md quotes at file:line; local
`bin/cosmic --make ci` reported `lint: PASS (629 files)` because
casts.md's `.lint` record was cached from before the source moved,
while the CI lane's cold gate failed `✗ docs/design/casts.md` with
`doc-citation: the quoted line is not cosmic/surface_test.tl:92`.
Running `o/bin/cosmic --check lint docs/design/casts.md` directly (no
cache) reproduced the failure locally. Same cached-PASS class as
3ICDLcm2 (reads lint) but a different edge: the fix is dependency
edges from a doc's lint record to every file its citations name — the
citations are already parsed, so the file list exists at record time;
o/project.mk's srcdeps mechanism is the pattern. Until then, every
slice that moves quoted lines discovers the failure one CI round late,
which is exactly the cycle the incremental cache exists to save.
