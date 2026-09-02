## Goal

Line-level C coverage of the Lua binding sources via gcc's own
`-fprofile-arcs -ftest-coverage`, with the runtime the cosmocc tarball
does not ship provided in-tree and the notes/data paths surviving
tlscc, so `make MODE=cov o/cov/tool/lua/test` leaves a `.gcno` and a
`.gcda` beside every instrumented object and the host `gcov` reads
them.

## Evidence

Item 3Il1RVDaKyr00zNMfdvnoW6jglZ `## Result`, all measured on
toolchain 2025.12.30 (gcc 14.1.0), host gcc/gcov 13.3.0, llvm-cov 18.1.3:

- cosmocc instruments (`__gcov0.*` counters, `_sub_I_00100_0` ctor →
  `__gcov_init`, `_sub_D_00100_1` dtor → `__gcov_exit`, notes stamped
  `B41*`); `libc/intrin/gcov.S` (LIBC_INTRIN, libc/intrin/BUILD.mk:156)
  defines those symbols as WEAK no-ops, so the link succeeds and nothing
  is written. Cosmo runs prioritized `.init_array.00100`/
  `.fini_array.00100` entries (ape/ape.lds:430-441,
  libc/runtime/cosmo2.c:189, libc/runtime/exit.c:50) — verified.
- No existing runtime fits: the host gcc-13 libgcov expects
  `n_functions` at `gcov_info+0x60` (8 `merge[]` slots) and version
  `B33*`; gcc-14 objects carry 9 slots, `n_functions` at +0x68 and
  `B41*`. Patching the version word alone → runs, exit 0, no `.gcda`,
  no open. The writer must follow GCC 14.1's `libgcc/libgcov.h`
  layout: version, next, stamp, checksum, filename, merge[9],
  n_functions, functions; fn_info: key, ident, lineno_checksum,
  cfg_checksum, ctrs[] of {num, values}.
- Under make, gcc never sees the object path: `build/bootstrap/tlscc`
  (tool/build/tlscc.c:262-266, 396-400) rewrites `-c -o X.o` to
  `-S -o $TMPDIR/tlscc-<x>.s` and assembles separately. Make's exact
  line for lpath.o plus the two flags produced `lpath.o` and NO
  `.gcno` beside it, with or without the compile.ape wrapper; the
  notes landed as `/tmp/tlscc-<x>.gcno` (7394 bytes) and the object's
  embedded data path is `/tmp/tlscc-<x>.gcda`. With gcc invoked
  directly on the same flags the notes land beside the object.
  Measured fix on the gcc line tlscc emits: `-dumpdir <objdir>/
  -dumpbase lpath.o` yields `<objdir>/lpath.o.gcno` and an embedded
  `<objdir>/lpath.o.gcda`; `-fprofile-note=` alone moves only the
  notes, the data path stays under /tmp.
- Reader: host `gcov` 13.3 reads `B41*` notes with the warning
  `version 'B41*', prefer 'B33*'` and proceeds (`gcov -f lpath.gcno`:
  9 functions, `Lines executed:0.00% of 85`, writes `lpath.c.gcov`);
  `llvm-cov gcov` 18.1.3 prints `Invalid .gcno File!` on the same
  files. The cosmocc tarball ships no gcov tool.

## Change

1. `build/config.mk`: a `MODE=cov` block modelled on `dbg`
   (ENABLE_FTRACE=1, -O0, `-DMODE_COV`), NOT adding the coverage flags
   globally.
2. `tool/net/BUILD.mk`, `tool/lua/BUILD.mk`, `third_party/lua/BUILD.mk`:
   `ifeq ($(MODE),cov)` per-object `private CFLAGS += -fprofile-arcs
   -ftest-coverage -dumpdir $(@D)/ -dumpbase $(@F)` on exactly the
   binding objects (the TOOL_LUA_LUA_MODULES list plus lfuncs.o and
   lunix.o), same `private` shape as `o/$(MODE)/tool/net/lsqlite3.o:`
   at tool/net/BUILD.mk:122. First verify tlscc forwards `-dumpdir`/
   `-dumpbase` untouched (it copies args and rewrites only `-c`/`-o`;
   measured so far only on the gcc line it emits); if it does not,
   teach tlscc to append them from its own `output` when it sees
   `-ftest-coverage`. Expected result per object: `o/cov/<path>/<stem>.o.gcno`
   and an embedded `o/cov/<path>/<stem>.o.gcda` (absolute).
3. A real runtime, `libc/intrin/gcov.c`, compiled only when
   `MODE_COV` is defined and replacing the weak stubs: `__gcov_init`
   chains each `struct gcov_info` onto a list; `__gcov_exit` writes
   `info->filename` in the format of GCC 14.1's `gcc/gcov-io.h` /
   `libgcc/libgcov.h` — READ those headers from the 14.1 source for
   the record encoding (magic `gcda`, version = info->version, stamp,
   checksum, then per function a GCOV_TAG_FUNCTION record and one
   GCOV_TAG_FOR_COUNTER(i) record per non-empty counter set; verify
   the length unit in gcov-io.h). No merge with an existing file: the
   test rule deletes `o/cov/**/*.gcda` before the run.
   `__gcov_merge_add` and the fork/exec hooks stay no-ops.
4. Reader: the host `gcov` (13.3 or newer), run from the object
   directory with `-o`: `gcov -o o/cov/tool/net o/cov/tool/net/lsqlite3.o.gcno`
   (expect the `prefer 'B33*'` warning; treat it as noise). Not
   `llvm-cov gcov`, not a hand-written reader.
5. `make MODE=cov o/cov/tool/lua/test`, then step 4 on
   `tool/net/lsqlite3.c` — record the lines-executed percentage in the
   PR; measure once per binding file.

## Non-goals

- No change to default, rel, or dbg mode flags; nothing in a shipped
  binary changes (the runtime file is `MODE_COV`-only).
- No ratchet in this item — the function-level floor from
  3Il1RfbQnDkO4vgNmWp2BAVip7R stays the gate; swapping it to line
  counts is a follow-on once the numbers exist.
- No upstream (jart/cosmopolitan) reformatting; the stubs file keeps
  its shape.

## Acceptance

- `make MODE=cov o/cov/tool/lua/test` passes and leaves a `.gcno` and
  a `.gcda` beside each instrumented object under `o/cov/` (one pair
  per binding object; none under `/tmp`); `make o//tool/lua/test`
  (default mode) is byte-for-byte unaffected.
- `strings o/cov/tool/net/lpath.o | grep '\.gcda$'` prints a path
  under `o/cov/`, not `/tmp/tlscc-*`.
- The host `gcov` prints a per-file `Lines executed` for all fourteen
  sources; `tool/net/lsqlite3.c` reports a non-zero percentage and the
  PR body carries the table (file, lines, covered).
- Probe from the research item repeated in-tree: a `printf`-only
  `main` compiled with the cov flags under MODE=cov writes a `.gcda`
  whose header reads `gcda B41*`, and `gcov` reports its one line as
  executed.
