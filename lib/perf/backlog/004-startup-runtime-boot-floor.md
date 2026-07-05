# 4. startup: runtime boot floor (cosmopolitan side)

- status: open — cosmic-side import-deferral step rejected (2026-07-04);
  the cosmopolitan-side floor is unworked
- layer: cosmopolitan
- scenario: startup_run_lua (and every other startup_* scenario)

- evidence: `startup_run_lua` was ~14.5-19ms for `print()`; after
  entry 3's step (a) fix it measured 5.7-8.4ms across two runs on a
  noisy machine (re-baseline before trusting an absolute number here).
  cpu/wall ~0.2-0.3 per recent baselines — mostly NOT CPU.
- eager `require("tl")` (entry 3) turned out to be the dominant cost
  this entry originally attributed to "eager cosmic-side module
  loading in main.tl" generally; with it gone, remaining floor is the
  APE loader + zip filesystem + Lua init + cosmic's other top-level
  `require`s (getopt, args, help, main_handlers, etc.).
- rejected cosmic-side attempt: deferred
  `local help = require("cosmic.help")` in main.tl to inside the
  `if opts.help then` branch (the only place it's used).
  `bin/make perf-compare` from a clean re-baseline showed
  `startup_run_lua` +4.0% — noise (±10.0% bar), not a real
  regression, but also not a measurable improvement. A quick manual
  A/B first (alternating runs of a trivial `.lua` script, ~30-50
  iterations each way) had already shown the same thing: differences
  bounced both directions across repeats. `getopt`/`args`/
  `main_handlers` can't be deferred the same way (needed on every
  invocation to parse args and dispatch), so there wasn't a second
  candidate to combine with `help` for a larger, clearer effect.
  Reverted the change.
- current hypothesis: the floor is dominated by something below the
  Lua-require level entirely — the APE loader, zip filesystem init,
  or Lua runtime boot, all of which live in whilp/cosmopolitan. Work
  it with the loop in `lib/perf/optimize/cosmopolitan.md`.
- decomposition measured (2026-07-05, shell-loop scouting on the CI
  container — re-measure with the real scenarios before optimizing):
  - raw pinned cosmos `lua -e 'print("hi")'`: ~5.0ms/invocation.
  - `cosmic -e 'print("hi")'`: ~7.8ms/invocation.
  - so the APE+Lua floor (~5ms) is the bigger half, and cosmic's
    payload/CLI boot adds ~2.8ms on top.
  - cosmo `--strace` shows 279 userspace-traced calls for cosmic vs
    47 for raw lua: cosmic's extra work is 16 `require()`s (14
    cosmic modules, ~44KB of .lua source), 29 `inflate()` calls
    (every module is deflate-compressed in the zip — entry 24 covers
    eliminating these; a store-mode probe put that slice at
    ~0.5ms), and zipos open/readv/fstat per module.
  - kernel-level strace shows ~195 rt_sigprocmask and ~115 mmap
    calls per trivial run — entry 27 covers that slice.
  - also observed under `--strace`: failed openat probes for
    `cosmic.dbg`/`cosmic.com.dbg` plus an `OpenSymbolTable()
    ENOEXEC` and a second whole-binary (6.6MB) MAP_PRIVATE mmap at
    every boot — likely ShowCrashReports() symbol-table eagerness
    (third_party/lua/lua.main.c:394), but verify it happens in
    plain (non---strace) runs before spending effort on it.
- remaining in this entry once 24 and 27 are worked: the ~5ms raw
  floor itself (APE loader, zipos central-directory init for a
  300+-entry archive, Lua state construction) and the Lua-parse
  cost of the ~44KB of boot modules (precompiling the payload to
  Lua 5.4 bytecode is a candidate — same interpreter build on
  every platform makes bytecode portable across the fat binary's
  architectures, but verify aarch64/x86_64 chunk compatibility
  before trusting that).
- risk: unknown per sub-hypothesis; the decomposition above is the
  map.
