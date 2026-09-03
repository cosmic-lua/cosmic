## Evidence

Split from `h38H_4UJ0` ("sqlite extension registry: extract the
remaining fifteen ext/misc units in three batches"), whose spec named
three batches landing as three separate PRs. Batch 2 (`decimal fileio
ieee sha shathree`) landed as cosmic-lua/cosmopolitan#370, accepted on
`h38H_4UJ0` directly. Batch 1 (`appendvfs base64 base85 completion
dbdata`) hit a real blocker — filed separately as `3InoAi3bSUyDIgESDOlE6CIBbi4`
(dbdata's shell.c marker lives under `ext/recover/` not `ext/misc/`;
base64/base85's init declarations are wrapped in `#ifndef
SQLITE_SHELL_EXTFUNCS`, breaking the test's literal substring check) —
and was not opened. This item is the third: batch 3, `sqlar stmtrand
uint`, which extracted cleanly with no marker or definition-check
complications.

## Change

Land the 3 units (`sqlar stmtrand uint`) in the sqlite extension
registry, the same rule #356 (item 3If5rH0S) and batch 2 (#370) used:
add each to `THIRD_PARTY_SQLITE3_A_SRCS`/`_OBJS`, declare its init in
`extensions.h`, append it to the registry (`extensions.c`) and the
`---@alias lsqlite3.Extension` union in `definitions.lua`, against
`master` of cosmic-lua/cosmopolitan, green on `make -j$(nproc)
o//tool/lua/test`, with the size delta in the PR body. No
`MARKER_STEM` override needed — all three keep their shell.c stem.

## Non-goals

- Registers nothing; no per-connection API.
- No change to `zipfile`'s unconditional registration.
- No new third-party code.
- Not batch 1 or the questions `3InoAi3bSUyDIgESDOlE6CIBbi4` raises —
  that item is independent of this one.

## Acceptance

A PR against cosmic-lua/cosmopolitan `master` extracting exactly
`sqlar`, `stmtrand`, `uint`, green on `make -j$(nproc)
o//tool/lua/test`, with `tool/lua/test_sqlite_extensions.lua`'s
registry-agreement test passing for all 11 units then in the registry
(the 8 already landed by #356 and #370, plus these 3).
