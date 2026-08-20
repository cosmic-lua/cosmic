Evidence from the 3I7PFJE7 bounce, 2026-08-20: a Lua VM has one
debug-hook slot per thread, so _fuzz/driver.tl's per-input instruction
budget (debug.sethook count hook) and cosmic.coverage's collector
cannot both be armed — under `--make coverage` the incumbent is
cosmo.cov's C hook (cosmic/coverage/init.tl:48), which debug.gethook()
reports as the uncallable string "external hook", so the budget stands
down there and the instrumented stage runs with no hang protection.
The composition fix is C-side, in whilp/cosmopolitan: cosmo.cov's hook
already fires per line; give it an optional instruction-or-line budget
(or expose hook composition), and the driver uses it when present so
the budget holds under instrumentation too. Cross-repo: the board's
`repo:` field (PR #1286) is the vehicle once it lands. Candidate parent:
the cosmic.fuzz epic 3I1j7yQA, near its crash-isolation child.
