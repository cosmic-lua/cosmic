# 28. embed.run() force-deflates embedded .lua; produced apps inflate at boot

- status: done (2026-07-05)
- layer: cosmic (lib/cosmic/embed.tl)
- scenario: embed_run_startup (new, lib/perf/bench/embed_startup_bench.tl)

- evidence: entry 024 stored cosmic's own boot-critical .lua so it no
  longer inflate()s the stdlib at startup. `embed.run()` — which
  bundles a user app into a copy of the cosmic binary — did the
  opposite: it added EVERY embedded file with `method = "deflate"`
  (embed.tl:276), so the produced executable inflate()d its own .lua
  on every launch. Measured on a 25-module app
  (`packed --strace | grep -c inflate`): 26 boot inflate() calls,
  all of them the app's embedded .lua (cosmic's stdlib is already
  stored post-024). Forcing deflate also grew tiny .lua ABOVE their
  source size (deflate overhead), so it cost both space and time.
- fix: store .lua uncompressed, deflate everything else. One line in
  run()'s add loop —
  `method = (stored_name ends in ".lua") and "store" or "deflate"`.
  The czip appender already supports `method="store"`; bulk assets
  (data, images, binaries) stay deflated since the entry point does
  not necessarily read them at startup.
- new scenario: `embed_run_startup` builds a 10-module app, embeds it
  once (the megabyte base-binary copy is fixed setup, not timed), and
  measures the produced executable's cold start with a functional
  check on its output.
- results:
  - boot inflate() calls (25-module app): 26 -> 0 (strict, deterministic).
  - `bin/make perf-compare`: 0 regressions, 33/33 ok. `embed_run_startup`
    read +0.6% (within its ±10% bar) — same harness-resolution limit as
    entry 024: the scenario spawns the app from cosmic, so cpu/wall ~0.20
    and parent fork/exec dominates the wall time, burying the child's
    boot-CPU win.
  - controlled A/B (two produced binaries differing only by embed's .lua
    compression, both assimilated to native ELF, 1800 runs each in
    alternating 150-run blocks, pstdev 0.04-0.06ms): 4.068 -> 3.770 ms,
    -7.3% median (-7.0% min).
  - size: +91KB (+1.3%) for a 108KB-source app — bounded to .lua code;
    assets stay compressed.
- correctness: `bin/make ci` green. embed_test.tl gains
  `test_embed_stores_lua` (a .lua embeds as method=0, content
  round-trips) alongside the existing `test_embed_uses_deflate` (a
  .txt still embeds as method=8). The extract->embed roundtrip is
  unaffected — extract rewrites files from decompressed content, so it
  never depended on the stored method.
- cross-reference: entry 024 fixed the same inflate-at-boot cost for
  cosmic's own payload; this is its embed-produced-executable analog.
- risk: low — behavior change is compression method only (zipos serves
  stored and deflated identically); the .lua policy is the same one 024
  validated for the base binary.
