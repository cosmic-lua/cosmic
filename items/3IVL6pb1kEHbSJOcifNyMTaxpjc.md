Running a runner-mode test file directly — `cosmic foo_test.tl` —
silently runs ZERO tests and exits 0. The script path compiles via
teal.compile_cached, lax and seam-less (_cli/main_handlers.tl:37-53,
cosmic/teal.tl:214-227); the D29 seam exists only in the build's
compile verb (_cli/build/work.tl:210) and the --compile/--check
handlers. A migrated file defines its tests, calls nothing, and lax
compile raises no unused-local error — a silent false pass where a
legacy file actually ran its tests. Affects all ~115 migrated files
today and every user project post-migration. This is the general form
of two existing items: 3IUKyP4L (pr.yml's smoke lane runs five test
files as bare scripts) and adjacent to 3IU4umVT (compile seam misses
--make check); the fix is one — the script path applies the same seam
(or refuses to run a runner-mode test file bare) — so refine these
together in plan.
