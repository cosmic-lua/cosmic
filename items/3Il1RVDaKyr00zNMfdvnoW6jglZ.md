## Question

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

## Method

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

## Deliverable

Board state, not a diff: this item's spec replaced by a `## Result`
carrying the measured answers to (1)-(4) with commands and output, and
the follow-on item (the ratchet) re-specced with the working mechanism
named — or, if nothing works, re-specced to the function-level
fallback and the reason.

## Non-goals

- No committed change to `build/config.mk` or any BUILD.mk from this
  slice; the scratch block is measurement only.
