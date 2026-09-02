## Goal

Line-level C coverage of the Lua binding sources via gcc's own
`-fprofile-arcs -ftest-coverage`, with the runtime the cosmocc tarball
does not ship provided in-tree, so `make MODE=cov o/cov/tool/lua/test`
leaves a `.gcda` beside every instrumented object.

## Evidence

Item 3Il1RVDaKyr00zNMfdvnoW6jglZ `## Result`: cosmocc 14.1.0
instruments (`__gcov0.*` counters, `_sub_I_00100_0` ctor →
`__gcov_init`, `_sub_D_00100_1` dtor → `__gcov_exit`, `.gcno` stamped
`B41*`); `libc/intrin/gcov.S` (built into LIBC_INTRIN,
libc/intrin/BUILD.mk:156) defines those symbols as WEAK no-ops so the
link succeeds and nothing is written; cosmo runs prioritized
`.init_array.00100`/`.fini_array.00100` entries (ape/ape.lds:430-441,
libc/runtime/cosmo2.c:189, libc/runtime/exit.c:50) — verified with a
probe binary. The host gcc-13 libgcov is unusable: version check
`B33*` vs compiler `B41*`. No gcov reader is in the toolchain and the
host `gcov` 13.3 does not natively read `B41*` files; the repo's make
calls `x86_64-linux-cosmo-gcc -c -o o/$(MODE)/<path>.o` directly so
`.gcno` lands beside each object (unlike the `cosmocc` wrapper, which
loses the x86_64 `.gcno`).

## Change

1. `build/config.mk`: a `MODE=cov` block modelled on `dbg`
   (ENABLE_FTRACE=1, -O0, `-DMODE_COV`), NOT adding the coverage flags
   globally.
2. `tool/net/BUILD.mk`, `tool/lua/BUILD.mk`, `third_party/lua/BUILD.mk`:
   `ifeq ($(MODE),cov)` per-object `private CFLAGS += -fprofile-arcs
   -ftest-coverage` on exactly the fourteen binding objects (the
   TOOL_LUA_LUA_MODULES list plus lunix.o), same `private` shape as
   `o/$(MODE)/tool/net/lsqlite3.o:` at tool/net/BUILD.mk:122.
3. A real runtime, `libc/intrin/gcov.c`, compiled only when
   `MODE_COV` is defined and replacing the weak stubs: `__gcov_init`
   chains each `struct gcov_info` onto a list; `__gcov_exit` writes
   `<info->filename>` (already the absolute `.gcda` path) in the format
   of GCC 14.1's `gcc/gcov-io.h` / `libgcc/libgcov.h` — READ those
   headers from the 14.1 source for the struct layout
   (version/next/stamp/checksum/filename/merge[]/n_functions/functions;
   fn_info key/ident/lineno_checksum/cfg_checksum/ctrs[]) and the
   record encoding (magic `gcda`, version = info->version, stamp,
   checksum, then per function a GCOV_TAG_FUNCTION record and one
   GCOV_TAG_FOR_COUNTER(i) record per non-empty counter set; lengths
   are in the unit GCC 14 uses, verify it in gcov-io.h). No merge with
   an existing file: the rule deletes `o/cov/**/*.gcda` before the run.
   `__gcov_merge_add` and the fork/exec hooks stay no-ops.
4. Reader: prefer `llvm-cov gcov` (host clang is present) if it accepts
   the `B41*` pair; otherwise a ~150-line Lua reader of `.gcno` (function
   and line records) + `.gcda` (arc counters) run by `lua.dbg`, output a
   per-file `lines, covered` table.
5. `make MODE=cov o/cov/tool/lua/test`, then the reader on
   `o/cov/tool/net/lsqlite3.gcno/.gcda` — record the lines-executed
   percentage in the PR; measure once per binding file.

## Non-goals

- No change to default, rel, or dbg mode flags; nothing in a shipped
  binary changes (the runtime file is `MODE_COV`-only).
- No ratchet in this item — the function-level floor from
  3Il1RfbQnDkO4vgNmWp2BAVip7R stays the gate; swapping it to line
  counts is a follow-on once the numbers exist.
- No upstream (jart/cosmopolitan) reformatting; the stubs file keeps
  its shape.

## Acceptance

- `make MODE=cov o/cov/tool/lua/test` passes and leaves fourteen
  `.gcda` files beside the instrumented objects under `o/cov/`;
  `make o//tool/lua/test` (default mode) is byte-for-byte unaffected.
- The reader prints a per-file table (file, lines, covered) for all
  fourteen sources; `tool/net/lsqlite3.c` reports a non-zero
  lines-executed percentage and the PR body carries the table.
- Probe from the research item repeated in-tree: a `printf`-only
  `main` compiled with the cov flags under MODE=cov writes a `.gcda`
  whose header reads `gcda B41*`.
