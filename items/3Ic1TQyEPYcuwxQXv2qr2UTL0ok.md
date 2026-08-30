Evidence (builder of PR #1541, 2026-08-30, reproduced twice): with a
real mutation live in `_make/clean.tl` (`is_worktree_root` stubbed to
`return false`) and the mutated `_make/clean.lua` confirmed embedded
byte-for-byte in the rebuilt `o/bin/cosmic`, the narrow test command
`bin/cosmic --make test _make/clean_test.tl` reported GREEN, while
running the compiled `o/_make/clean_test.lua` directly under the same
binary correctly reported the failure
(`✗ test_clean_keeps_a_git_worktree ... 2 passed, 1 failed`), and a
hand-built fixture project outside the harness agreed with the direct
run (the worktree got deleted). A false green from the narrow path
can mask a real regression for any session that trusts
`--make test <path>` — the exact command AGENTS.md and every builder
brief recommend for fast iteration. To reproduce: mutate
is_worktree_root in _make/clean.tl, rebuild, compare
`--make test _make/clean_test.tl` against directly running the
compiled test file. Root-cause where the narrow path diverges (stale
compiled test? discovery skipping the file? runner-mode tail?) and fix
so the narrow form runs what the full run runs.
