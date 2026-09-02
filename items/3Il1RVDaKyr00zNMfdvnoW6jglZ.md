## Evidence

Can the fork's toolchain produce C line coverage for the Lua binding
sources at all? Two unknowns, in order: (1) does `cosmocc` accept
`-fprofile-arcs -ftest-coverage` and link `libgcov` (the cosmocc
tarball may not ship it); (2) does an APE binary so built write
`.gcda` files on exit under cosmopolitan's libc (gcov's runtime uses
`atexit`, `fopen` and `getenv("GCOV_PREFIX")`, all of which the libc
provides, but the fat-binary startup and `MODE`-specific link flags
may interfere). Nothing measured yet: no cosmocc was present on the
measuring machine 2026-09-02, and `build/config.mk` shows no mode with
coverage flags (modes at lines 12-241; `dbg` at 152-162 is the
closest shape: `-O0`, `-fsanitize=undefined`, `-fno-pie`).

## Change

On a checkout with the toolchain (`make` downloads it into
`.cosmocc/`):

1. `printf 'int main(){return 0;}' > t.c; .cosmocc/*/bin/cosmocc
   -fprofile-arcs -ftest-coverage -o t t.c; ./t; ls *.gcda` — record
   the compiler output and whether a `.gcda` appears.
2. If (1) links: add a scratch `MODE=cov` block to `build/config.mk`
   modelled on `dbg` with `CONFIG_COPTS += -fprofile-arcs
   -ftest-coverage` restricted (via a per-directory override in
   `tool/net/BUILD.mk` and `third_party/lua/cosmo`'s BUILD.mk, not
   globally) to the binding sources; `make MODE=cov o/cov/tool/lua/test`;
   record whether `.gcda` files land beside the objects, and run
   `gcov` (or `.cosmocc/*/bin/x86_64-linux-cosmo-gcov`) on
   `tool/net/lsqlite3.c` to read a lines-executed percentage.
3. If (2) works, measure once per binding file and record the table
   (file, lines, covered) — that table is the first floor.
4. If either step fails, record the exact error and the nearest
   alternative: a `--coverage`-free approach such as `-fsanitize=
   coverage` with cosmopolitan's own `__sanitizer_cov_trace_pc_guard`
   hooks, or a `dbg`-mode `--ftrace` log post-processed into per-
   function hit counts (function-level, not line-level).

## Deliverable (board state, no product PR)

Board state, not a diff: this item's spec replaced by a `## Result`
carrying the measured answers to (1)-(4) with commands and output, and
the follow-on item (the ratchet) re-specced with the working mechanism
named — or, if nothing works, re-specced to the function-level
fallback and the reason.

## Non-goals

- No committed change to `build/config.mk` or any BUILD.mk from this
  slice; the scratch block is measurement only.

## Result

Measured 2026-09-02 on a fresh worktree of origin/master (3892e562),
toolchain `.cosmocc/2025.12.30-0c0b4c8c8` (gcc 14.1.0), host Ubuntu
24.04 with gcc/gcov 13.3.0 and llvm-cov 18.1.3. Tree left untouched.
Verdict: gcov instrumentation compiles, the host `gcov` reads what it
emits, but no gcov RUNTIME exists that matches this compiler's
`gcov_info` layout, so nothing writes a `.gcda`; the function-level
`--ftrace` fallback works today.

### (1) cosmocc accepts the flags but cannot link — NO

    $ printf 'int main(){return 0;}' > t.c
    $ .cosmocc/current/bin/cosmocc -fprofile-arcs -ftest-coverage -o t t.c
    .../libexec/gcc/x86_64-linux-cosmo/14.1.0/ld.bfd: cannot find -lgcov: No such file or directory
    collect2: error: ld returned 1 exit status
    (exit 1; no ./t, no .gcda)

`.cosmocc/*/bin/cosmocc` as written in the spec expands to two paths
(the versioned dir and the `current` symlink) and the second becomes
a linker input ("linker input file unused"); use
`.cosmocc/current/bin/cosmocc`.

The toolchain ships no gcov runtime and no gcov tool:

    $ find .cosmocc/current -iname '*gcov*'   → (nothing)
    $ find .cosmocc/current -name 'libgcc*'   → x86_64-linux-cosmo/lib/libgcc_s.a, aarch64-linux-cosmo/lib/libgcc_s.a
    $ ls .cosmocc/current/bin | grep gcov      → (nothing; 83 tools)

Compile-only instruments correctly (`cosmocc -fprofile-arcs
-ftest-coverage -c -o t.o t.c`, exit 0):

    $ x86_64-linux-cosmo-nm t.o
    b __gcov0.main   d __gcov_.main   U __gcov_exit   U __gcov_init   U __gcov_merge_add
    t _sub_D_00100_1 (.fini_array.00100)   t _sub_I_00100_0 (.init_array.00100)   T main

The only missing piece is a runtime defining `__gcov_init`,
`__gcov_exit`, `__gcov_merge_add`. The notes/data format stamped is
`B41*` (`od -c -N 8 v.gcno` → `o n c g * 1 4 B`).

### (2) not run as written — its gate ("If (1) links") was not met

What an in-tree `MODE=cov` would do, from the tree and from make's
own compile line run by hand:

`libc/intrin/gcov.S` ("Magic words to unbreak build if GCOV flags are
passed", built into LIBC_INTRIN at `libc/intrin/BUILD.mk:156`) defines
WEAK no-op `__gcov_init`, `__gcov_exit`, `__gcov_merge_add`,
`__gcov_fork`, `__gcov_exec*`, so `-fprofile-arcs` inside `make` links
and never writes anything. The lua link is `$(APELINK)` over `.a`
packages plus `$(CRT)` (`tool/lua/BUILD.mk:101-109`), never the gcc
driver, so `-lgcov` is never requested.

Where `.gcno` lands under make — measured with make's exact line:

    $ make -n -W tool/net/lpath.c o//tool/net/lpath.o
    .cosmocc/2025.12.30-0c0b4c8c8/bin/compile.ape -V9 -M2048m -P8192 -AOBJECTIFY.c build/bootstrap/tlscc \
      .cosmocc/2025.12.30-0c0b4c8c8/bin/x86_64-linux-cosmo-gcc -Wall -Werror ... -fpatchable-function-entry=18,16 \
      -g -ggdb ... -nostdinc -iquote. -isystem libc/isystem -DSYSDEBUG -DFTRACE -include libc/integral/normalize.inc \
      ... -std=gnu23 -fno-inline-functions-called-once -c -o o//tool/net/lpath.o tool/net/lpath.c
    (then compile.ape -AFIXUPOBJ build/bootstrap/fixupobj o//tool/net/lpath.o)

    (a) that line verbatim + `-fprofile-arcs -ftest-coverage`, `-o` to scratch/ape/lpath.o
        → exit 0; scratch/ape/ holds lpath.o ONLY
    (b) same without the compile.ape wrapper (tlscc + gcc)
        → exit 0; lpath.o only; /tmp now holds tlscc-7bffe10040f5e5f0.gcno, tlscc-f4f719667ef72174.gcno (7394 bytes each)
    (c) same flags, gcc invoked directly with no tlscc
        → exit 0; scratch/bare/ holds lpath.o AND lpath.gcno (7394 bytes)

`build/bootstrap/tlscc` (`tool/build/tlscc.c:262-266, 396-400`)
rewrites `-c -o X.o` into `-S -o $TMPDIR/tlscc-<x>.s` and assembles
separately, so gcc writes `/tmp/tlscc-<x>.gcno` and nothing moves it.
The object's embedded `.gcda` path follows the same temp name:

    $ strings scratch/ape/lpath.o  | grep '\.gcda$'   → /tmp/tlscc-7bffe10040f5e5f0.gcda
    $ strings scratch/bare/lpath.o | grep '\.gcda$'   → .../scratch/bare/lpath.gcda

What redirects both, measured on the gcc line tlscc emits (`-S -o
/tmp/tlscc-probe.s`):

    (d) + -fprofile-note=<objdir>/lpath.gcno   → lpath.gcno lands in <objdir>; embedded gcda still /tmp/tlscc-probe-d.gcda
    (e) + -dumpdir <objdir>/ -dumpbase lpath.o → <objdir>/lpath.o.gcno; embedded gcda <objdir>/lpath.o.gcda

So `-dumpdir $(@D)/ -dumpbase $(@F)` on the instrumented objects is the
fix a `MODE=cov` needs (measured on the gcc line, not yet through
tlscc's own arg copy). Note the bare gcc call needs the whole flag set
(`-nostdinc -iquote. -isystem libc/isystem -include
libc/integral/normalize.inc -std=gnu23 ...`): a trimmed one fails with
`cc1: error: no include path in which to search for stdc-predef.h` or
`unknown type name 'bool'`.

Nearest off-the-shelf runtime, probed: the host gcc-13
`/usr/lib/gcc/x86_64-linux-gnu/13/libgcov.a` (68002 bytes).

    $ x86_64-unknown-cosmo-cc -fprofile-arcs -ftest-coverage -c -o t.o t.c
    $ x86_64-unknown-cosmo-cc -o t t.o /usr/lib/gcc/x86_64-linux-gnu/13/libgcov.a
    ld.bfd: libgcov.a(_gcov.o): undefined reference to `__sprintf_chk' ... `__vfprintf_chk' ... `__isoc23_strtol' ... `__memcpy_chk' ... `__fprintf_chk'

(a fortified glibc build). With a 5-function shim
(`__sprintf_chk`→vsprintf, `__fprintf_chk`/`__vfprintf_chk`→vfprintf,
`__memcpy_chk`→memcpy, `__isoc23_strtol`→strtol) it links (2009486-byte
APE) and runs, but writes nothing:

    $ ./t; echo $?                                     → hi / 0 ; ls *.gcda → none
    $ GCOV_PREFIX=$PWD/pre GCOV_PREFIX_STRIP=99 ./t     → no .gcda under pre/
    $ ./t --strace 2>&1 | grep -iE 'gcda|openat'        → only the self-opens of ./t
    $ nm -S t | grep gcov   → __gcov_init (0xab) __gcov_exit (0x9d) __gcov_dump_one: libgcov's, not the stubs
    $ ./t2 --ftrace 2>&1 | grep _sub                    → _sub_I_00100_0 and _sub_D_00100_1 each called once
    ctor/dtor probe (priorities 100 and default)         → ctor100 ctordefault main dtordefault dtor100
    explicit __gcov_dump() from main                     → no open, no file, no diagnostic (GCOV_ERROR_FILE set too)

Cosmo's runtime is NOT the obstacle: `.init_array.00100` /
`.fini_array.00100` are collected (`ape/ape.lds:430-441`,
SORT_BY_INIT_PRIORITY) and run (`libc/runtime/cosmo2.c:189`,
`libc/runtime/exit.c:50`). The obstacle is the `gcov_info` STRUCT
LAYOUT, not just the version word:

    gcc-13 __gcov_init (objdump -d libgcov.a):
      mov (%rdi),%esi            ; version
      mov 0x60(%rdi),%eax        ; n_functions at +0x60  (8 merge[] slots)
      cmp $0x4233332a,%esi       ; == "B33*"
    gcc-14 gcov_info in t.o (.data+0x40, objdump -s/-r -j .data):
      +0x00 2a313442 "B41*"      +0x10 stamp 607b22d1   +0x14 checksum f9215888
      +0x18 filename → .rodata+8 +0x20 merge[0] → __gcov_merge_add, merge[1..8] = 0 (NINE slots)
      +0x60 = 00000000            +0x68 n_functions = 2   +0x70 functions → .data+0xf0
      (fn_info __gcov_.main at .data+0: key→info, ident, lineno_cksum, cfg_cksum, ctrs[0].num=3, values→__gcov0.main)

Version-only patch probe: rewrite the one `2a313442` in t.o to
`2a333342` (`B33*`), link with shim + host libgcov, run → exit 0,
still no `.gcda`, zero `.gcda` opens under `--strace`: gcc-13 reads
`n_functions` from +0x60, finds 0, returns before the version compare.
A runtime matching GCC 14.1's `libgcov.h` layout is required; no
version shim can bridge it.

### (3) no table — no `.gcda` was produced by any route.

### (4) alternatives

`-fsanitize=coverage` hooks: rejected by this gcc, and no
`__sanitizer_cov*` symbol exists anywhere in the tree:

    $ cosmocc -fsanitize-coverage=trace-pc-guard -c t.c
    x86_64-linux-cosmo-gcc: error: unrecognized argument in option '-fsanitize-coverage=trace-pc-guard'
    note: valid arguments to '-fsanitize-coverage=' are: trace-cmp trace-pc

Readers for the `B41*` files the compiler DOES emit (for the
line-level item): host `gcov` 13.3 reads them, `llvm-cov gcov` 18 does
not.

    $ gcov v.gcno
    v.gcno:version 'B41*', prefer 'B33*'
    v.gcda:cannot open data file, assuming not executed
    File 'v.c'  Lines executed:0.00% of 1  Creating 'v.c.gcov'
    $ gcov -f lpath.gcno          (the notes from (c))
    lpath.gcno:version 'B41*', prefer 'B33*'
    Function 'LuaPath' ... 'LuaPathIsdir' 'LuaPathIslink' 'LuaPathIsfile' 'LuaPathExists' 'CheckPath'
    'LuaPathJoin' 'LuaPathDirname' 'LuaPathBasename'   (9 functions)
    File 'tool/net/lpath.c'  Lines executed:0.00% of 85  Creating 'lpath.c.gcov'
    $ llvm-cov gcov v.gcno ; llvm-cov gcov lpath.gcno
    Invalid .gcno File!   (both; Ubuntu LLVM 18.1.3)

`--ftrace` function-level fallback: WORKS, measured three times on
the default-mode binary the test target builds (`o//tool/lua/lua.dbg`,
`-O2 -g -fpatchable-function-entry=18,16`, ENABLE_FTRACE=1; `dbg`
also has ENABLE_FTRACE=1, at `-O0`):

    $ cat ft.lua
    local s = require("cosmo.lsqlite3")
    local db = s.open_memory(); db:exec("create table t(x); insert into t values(1)")
    for r in db:nrows("select * from t") do end; db:close()
    local cov = require("cosmo.cov"); cov.start(); cov.stop()
    $ for i in 1 2 3; do o//tool/lua/lua.dbg --ftrace ft.lua 2> ft$i.log; done
    lines: 31992 / 31980 / 32027        distinct FUN names: 924 / 926 / 926
    whole-log set difference run1 vs run2 and run1 vs run3, exactly:
      __maps_add __maps_balloc __maps_compare __maps_free __tree_insert prepend_alloc   (allocator internals)
    binding-file covered set (name→file via nm -l on the same binary, clone suffixes stripped):
      18 functions in all three runs, byte-identical (cmp): 3 in tool/net/lcov.c
      (LuaCov LuaCovStart LuaCovStop), 15 in tool/net/lsqlite3.c (cleanupdb closevms
      create_meta db_close db_do_next_row db_exec db_gc db_next_named_row db_nrows dbvm_gc
      lsqlite_do_open lsqlite_open_memory luaopen_lsqlite3 newvm vm_push_column)

Log line: `FUN <pid> <tid> <ticks> <depth> <name>` (pid/tid carry ANSI
colour; `name` is the last field). Statics are named; optimizer
clones carry `.isra.N`/`.constprop.N`/`.part.N` (e.g.
`db_do_rows.isra.0`, `lsqlite_checkdb.constprop.0`); functions inlined
at `-O2` never appear — `MODE=dbg` (`-O0`) has no such hole. Objects
without ftrace padding (the host libgcov above) do not appear; every
in-tree object has it. Whole-log counts are NOT run-stable; the
per-binding-file covered SET is.

Denominator, from `x86_64-linux-cosmo-nm -l --defined-only
o//tool/lua/lua.dbg` (T/t symbols whose DWARF file is a binding
source; nm prints lfuncs.c as `<root>/./tool/net/lfuncs.c`, so paths
must be normalized): 545 functions in 13 files —

    lunix.c 264   lsqlite3.c 105   lfuncs.c 66   lzip.c 39   lfetch.c 13   llua.c 11
    lcosmo.c 9    lcov.c 9        lpath.c 9     lre.c 9     largon2.c 4   ljson.c 4
    lgetopt.c 3   (lfuncs3.c: 2 lines, no functions)

(`tool/net/lfuncs.c` is linked via the TOOL_NET package although it
is not in TOOL_LUA_LUA_MODULES; it counts.) Source line counts:
lunix.c 5190, lsqlite3.c 2880, lzip.c 2227, lfetch.c 1552, lfuncs.c
1317, llua.c 669, ljson.c 649, lcosmo.c 373, largon2.c 306, lre.c
301, lgetopt.c 270, lcov.c 269, lpath.c 173, lfuncs3.c 2.

### Verdict for the follow-ons

Line coverage needs new code in this repo: a `.gcda` writer for GCC
14.1's `gcov_info` layout plus `-dumpdir/-dumpbase` on the
instrumented objects so the notes and the data path survive tlscc;
the reader is the host `gcov` (any 13+/14 reads `B41*` with a
version warning), never `llvm-cov gcov`. The ratchet lands on the
function-level `--ftrace` route now (3Il1RfbQnDkO4vgNmWp2BAVip7R);
the line-level route is 3Il43qrU0v1rsyrdnssXqBUOjuH.
