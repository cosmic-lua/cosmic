# decisions

one line each, in the order they were made. the design describes the
result; this is the log.

1. Linux and macOS, no Windows.
2. C as host language; zig as toolchain only.
3. the database is the only module source; the build is fast,
   incremental, reproducible.
4. every binary carries all four core images; size yields to
   consistency and performance.
5. casts foreclosed; `any` only at shape boundaries.
6. one state, coroutines over `poll`, re-entrant C.
7. pristine sources committed; patches as exact records applied at
   build time.
8. the Teal layer written fresh; surface parity with any predecessor
   is not a goal.
9. mbedtls 3.6 with a bundled root store.
10. this branch becomes `main` at a named release bar.
11. a verb CLI.
12. an equivalent sandbox core on both OSes with a conformance suite;
    no default-deny for scripts.
13. milestones: hello from the database, then self-check.
14. zig's bundled musl is the libc; no vendored musl.
15. zig pinned by file, fetched and verified by `bin/zig`.
16. `build.zig` owns the C; `zig build boot` bridges once.
17. the syscall table is annotated C; types and docs derive from it.
