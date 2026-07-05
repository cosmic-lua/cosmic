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
- suggested first step (decomposition, not yet an optimization): time
  the pinned raw cosmos `lua` binary running `-e 'print("hello")'`
  next to cosmic's `startup_run_lua`. The gap isolates what cosmic's
  ~6MB zip payload adds to boot (zip central-directory scan, more
  package path entries) from the APE+Lua floor itself; whichever side
  is bigger tells you where to read C code first.
- risk: unknown until a concrete C-side hypothesis is formed.
