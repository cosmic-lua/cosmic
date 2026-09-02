## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#356 (item 3If5rH0S,
the sqlite extension registry). `third_party/sqlite3/update.sh`
fetches and rewrites `zipfile.c` from the sqlite source tree but knows
nothing about the newly extracted `series.c` and `regexp.c` (and the
batches that follow): a future version bump run through it refreshes
`shell.c` and leaves the extracted units at the old version. #356's
`tool/lua/test_sqlite_extensions.lua` asserts each unit equals
`shell.c`'s section with two lines restored, so the bump fails loudly
rather than silently, but nothing repairs it. The exact extraction
command is in #356's PR body. Re-measure at pull time: `grep -n
'zipfile\|series\|regexp' third_party/sqlite3/update.sh`.

## Change

`third_party/sqlite3/update.sh`: after refreshing `shell.c`, extract
every registry unit from its `shell.c` section by the same rule the
test applies (section bounds, `sqlite3ext.h` include rewritten to the
repo path, the `u8` typedef restored where the shell inliner removed
it), driven by the registry's name list so a new batch needs no
script edit; a `README.cosmo` note names the rule. A dry run on the
current tree must produce byte-identical units.

## Non-goals

- No new extraction; the batches are 3If5rH0S's follow-ups.
- No change to the agreement test.
