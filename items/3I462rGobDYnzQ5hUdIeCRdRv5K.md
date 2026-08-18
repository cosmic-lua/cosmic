Found while implementing item 3HyEEgwb (_eval journal bundler, PR whilp/cosmic#1263).

`_make/check_test.tl` and `_cli/main_handlers_test.tl` spawn child `cosmic --make …`
fixture processes via `child.start(argv, {cwd = dir})` without scrubbing the parent
environment first. When the *outer* test run needs `COSMIC_MAKE_ROOT` set (the
documented escape hatch for a checkout nested inside another project's root — see
`skills/work/parallel.md`'s "keep the worktrees out of the project root" section),
that variable leaks into the spawned fixture subprocess too, and the subprocess
resolves to the outer root instead of its own fixture root — corrupting both tests'
own root-detection assertions.

Reproduced by removing an unrelated, otherwise-passing change and rerunning just
these two test files under an outer `COSMIC_MAKE_ROOT`: byte-identical failures,
confirming the leak rather than any diff-specific cause.

This will not surface in the repo's own CI (which runs from an unambiguous root),
but it does surface for any implementer/orchestrator session whose worktree ends up
nested (a layout `parallel.md` already warns is easy to fall into), turning an
unrelated coverage/test run red and costing that session time misdiagnosing it as
their own regression.

Fix shape (not investigated further — out of scope for 3HyEEgwb): scrub
`COSMIC_MAKE_ROOT` (and any other `COSMIC_*` env the fixture subprocess should not
inherit) from the environment `child.start` passes to the spawned fixture process in
both tests, so each fixture's root detection is judged only on its own `cwd`.
