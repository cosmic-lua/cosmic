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
24.04 with gcc/gcov 13.3.0. Tree left untouched. The one-line verdict:
gcov instrumentation compiles but there is no gcov RUNTIME anywhere
that matches this compiler, so nothing writes a `.gcda`; the
function-level `--ftrace` fallback works today.

### (1) cosmocc accepts the flags but cannot link — NO

    $ printf 'int main(){return 0;}' > t.c
    $ .cosmocc/current/bin/cosmocc -fprofile-arcs -ftest-coverage -o t t.c
    .../libexec/gcc/x86_64-linux-cosmo/14.1.0/ld.bfd: cannot find -lgcov: No such file or directory
    collect2: error: ld returned 1 exit status
    (exit 1; no ./t, no .gcda, no .gcno)

Note `.cosmocc/*/bin/cosmocc` as written in the spec expands to two
paths (`2025.12.30-…` and the `current` symlink), so the second is
passed as a linker input ("linker input file unused"); use
`.cosmocc/current/bin/cosmocc`.

The toolchain ships no gcov runtime or tool at all:

    $ find .cosmocc/current -iname '*gcov*'        → (nothing)
    $ find .cosmocc/current -name 'libgcc*'
    ./x86_64-linux-cosmo/lib/libgcc_s.a
    ./aarch64-linux-cosmo/lib/libgcc_s.a
    $ ls .cosmocc/current/bin | grep gcov          → (nothing; 83 tools, no *-gcov)

Compile-only works and instruments correctly:

    $ cosmocc -fprofile-arcs -ftest-coverage -c -o t.o t.c     (exit 0)
    $ x86_64-linux-cosmo-nm t.o
    0000000000000000 b __gcov0.main
    0000000000000000 d __gcov_.main
                     U __gcov_exit
                     U __gcov_init
                     U __gcov_merge_add
    t _sub_D_00100_1   t _sub_I_00100_0   T main

so the only missing piece is a runtime defining `__gcov_init`,
`__gcov_exit`, `__gcov_merge_add`. The format the compiler stamps is
gcov `B41*` (`od -N 8 v.gcno` → `gcno` `B41*`, i.e. 0x4234312a).
Wrapper quirk: with `cosmocc -c` only `.aarch64/t.gcno` survives (the
x86_64 `.gcno` is written beside the wrapper's temp object); calling
`x86_64-linux-cosmo-gcc -c -o v.o v.c` directly — which is what the
repo's `make` does — puts `v.gcno` beside `v.o`.

### (2) not run — its gate ("If (1) links") was not met

What the tree says an in-tree `MODE=cov` would do, unmeasured:
`libc/intrin/gcov.S` ("Magic words to unbreak build if GCOV flags are
passed") defines WEAK no-op `__gcov_init`, `__gcov_exit`,
`__gcov_merge_add`, `__gcov_fork`, `__gcov_exec*`, built into
LIBC_INTRIN (`libc/intrin/BUILD.mk:156`). So `-fprofile-arcs` inside
`make` links fine and never writes a `.gcda`. The link is
`$(APELINK)` over `.a` packages plus `$(CRT)` (`tool/lua/BUILD.mk:101-109`),
never the gcc driver, so `-lgcov` is not even requested.

Nearest off-the-shelf runtime, probed: the host's gcc-13
`/usr/lib/gcc/x86_64-linux-gnu/13/libgcov.a` (68002 bytes).

    $ x86_64-unknown-cosmo-cc -fprofile-arcs -ftest-coverage -c -o t.o t.c
    $ x86_64-unknown-cosmo-cc -o t t.o /usr/lib/gcc/x86_64-linux-gnu/13/libgcov.a
    ld.bfd: libgcov.a(_gcov.o): undefined reference to `__sprintf_chk'
      ... `__vfprintf_chk' ... `__isoc23_strtol' ... `__memcpy_chk' ... `__fprintf_chk'

(Ubuntu's libgcov is a fortified glibc build.) With a 5-function shim
(`__sprintf_chk`→vsprintf, `__fprintf_chk`/`__vfprintf_chk`→vfprintf,
`__memcpy_chk`→memcpy, `__isoc23_strtol`→strtol) it links (2009486-byte
APE) and runs:

    $ ./t ; echo $?            → hi / 0
    $ ls *.gcda                → none
    $ GCOV_PREFIX=$PWD/pre GCOV_PREFIX_STRIP=99 ./t; find pre -name '*.gcda'  → none
    $ ./t --strace 2>&1 | grep -iE 'gcda|openat'   → only the self-opens of ./t, no .gcda
    $ nm -S t | grep gcov      → __gcov_init (0xab) __gcov_exit (0x9d) __gcov_dump_one … : libgcov's, not the stubs
    $ ./t2 --ftrace | grep _sub → _sub_I_00100_0 and _sub_D_00100_1 both called once
    destructor test (ct.c)     → ctor100 ctordefault main dtordefault dtor100 (all priorities run)
    explicit __gcov_dump() from main → still no open, no file, no diagnostic (even with GCOV_ERROR_FILE)

So cosmo's runtime is NOT the obstacle — `.init_array.00100` /
`.fini_array.00100` are collected (`ape/ape.lds:430-441`,
SORT_BY_INIT_PRIORITY) and run through `libc/runtime/cosmo2.c:189` and
`libc/runtime/exit.c:50`. The obstacle is the format version: gcc-13's
runtime checks `cmpl $0x4233332a` (= `B33*`) in `gcov_version` and
`__gcov_init` declines mismatched info before registering it, while the
14.1 compiler stamps `B41*`. A matching runtime would have to be built
from GCC 14.1's `libgcc/libgcov-*.c` against cosmo, or written in-tree.

### (3) no table — no `.gcda` was produced by any route.

### (4) alternatives

`-fsanitize=coverage` hooks: rejected by this compiler, and the tree
has no `__sanitizer_cov*` symbol anywhere (`grep -rn sanitizer_cov` →
nothing):

    $ cosmocc -fsanitize-coverage=trace-pc-guard -c t.c
    x86_64-linux-cosmo-gcc: error: unrecognized argument in option '-fsanitize-coverage=trace-pc-guard'
    note: valid arguments to '-fsanitize-coverage=' are: trace-cmp trace-pc

`--ftrace` function-level fallback: WORKS, measured on the default-mode
binary the test target already builds (`o//tool/lua/lua.dbg`, `-O2 -g`,
ENABLE_FTRACE=1; `dbg` has ENABLE_FTRACE=1 too, at `-O0`):

    $ cat ft.lua
    local s = require("cosmo.lsqlite3")
    local db = s.open_memory(); db:exec("create table t(x); insert into t values(1)")
    for r in db:nrows("select * from t") do end; db:close()
    local cov = require("cosmo.cov"); cov.start(); cov.stop()
    $ o//tool/lua/lua.dbg --ftrace ft.lua 2> ftrace.log
    $ wc -l < ftrace.log                                → 32050
    $ awk '$1=="FUN"{print $NF}' ftrace.log | sort -u | wc -l   → 924 distinct functions
    $ awk '$1=="FUN"{print $NF}' ftrace.log | sort | uniq -c | grep -E ' (LuaCov|lsqlite_|db_|dbvm|cleanupdb|luaopen_lsqlite3)'
          1 LuaCov            1 LuaCovStart        1 LuaCovStop
          1 cleanupdb         1 db_close           2 db_do_next_row
          1 db_do_rows.isra.0 1 db_exec            1 db_gc
          2 db_next_named_row 1 db_nrows           1 dbvm_gc
          3 lsqlite_checkdb.constprop.0            1 lsqlite_do_open
          1 lsqlite_open_memory                    1 luaopen_lsqlite3

Log format: `FUN <pid> <tid> <ticks> <depth> <name>` (ANSI-coloured pid/tid;
name is the last field). Static functions are named, optimizer clones
carry `.isra.N`/`.constprop.N`/`.part.N` suffixes (strip for
attribution), and functions inlined at `-O2` are invisible — `MODE=dbg`
(`-O0`) removes that hole. Name→file attribution comes from the same
binary's DWARF (`x86_64-linux-cosmo-nm -l --defined-only lua.dbg`).
Functions from objects not built with ftrace padding (e.g. the host
libgcov.a above) do not appear; every in-tree object has it.

Binding sources linked into `lua.dbg` (`tool/lua/BUILD.mk:26-38` plus
`third_party/lua/cosmo/lunix.c` via THIRD_PARTY_LUA), the follow-on's
denominator set:

    5190 third_party/lua/cosmo/lunix.c    2880 tool/net/lsqlite3.c
    2227 tool/net/lzip.c                  1552 tool/net/lfetch.c
    1317 tool/net/lfuncs.c                 669 tool/net/llua.c
     649 tool/net/ljson.c                  373 tool/lua/lcosmo.c
     306 tool/net/largon2.c                301 tool/net/lre.c
     270 tool/net/lgetopt.c                269 tool/net/lcov.c
     173 tool/net/lpath.c                    2 tool/lua/lfuncs3.c

### Verdict for the follow-on

Line coverage has no working mechanism without new code in this repo
(a `B41*`-format `.gcda` writer, plus a reader: the host `gcov` 13.3
does not read `B41*` files natively and the toolchain ships none).
The ratchet lands on the function-level `--ftrace` route now; the
line-level route is captured as its own optional item.
