## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#359 (item 3Il43qrU,
MODE=cov). The in-tree `.gcda` writer in `libc/intrin/gcov.c` writes
each instrumented object's counters at process exit with no merge, as
that spec asked ("No merge with an existing file: the test rule
deletes `o/cov/**/*.gcda` before the run"). `o/cov/tool/lua/test`
runs about 65 test processes, so the surviving `.gcda` holds only
the LAST process's counts (`test_definitions_conformance.lua` on
#359): `lsqlite3.c` reports 2.42% of 1034 lines (module init only)
and `llua.c` 0%, when the suite exercises far more. Suite-wide line
numbers, and any line-count ratchet built on them, need libgcov's
normal read-add-write. Re-measure at pull time: `make MODE=cov
o/cov/tool/lua/test && gcov -o o/cov/tool/net o/cov/tool/net/
lsqlite3.o.gcno | grep Lines`.

## Change

`libc/intrin/gcov.c` `__gcov_exit`: if `info->filename` exists and
its header (magic, version, stamp) matches, read its counter records
and add them to the live counters before writing (GCC 14.1's
`libgcov-driver.c` merge; `__gcov_merge_add` semantics), with a
length/checksum mismatch treated as a fresh file. The cov test rule
keeps deleting `.gcda` before the run so a build starts clean. Record
the per-file `Lines executed` table after the change in the PR; a
follow-on item may then ratchet it.

## Non-goals

- No change outside `MODE_COV`; default, rel and dbg binaries
  unchanged byte-for-byte.
- No ratchet in this item.
