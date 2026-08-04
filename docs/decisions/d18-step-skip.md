# D18 — expensive recipe steps skip on input bytes, not just on mtime

- **date:** 2026-08
- **context:** make schedules on mtime, and mtimes lie in exactly the
  situations that hurt: a branch switch restamps every source, a CI
  cache restore sits under a fresh checkout, a `touch` sweep — and the
  graph re-runs the world to reproduce bytes it already has. D17 made
  invalidation precise about the TOOL; this is the same honesty about
  the WORK. `engine.md` had already named the general form — "an
  action cache keyed on (argv + input hashes), deferred until
  profiling justifies it" — and the profiling that motivated this
  series justifies it: a full recompile costs ~33s and a full test
  sweep minutes, where verifying that nothing changed costs seconds.
- **decision:** the two steps that do real work per source gain a
  content key. `compile` and `record` (in `_cli/build/work.tl`) hash
  their stable argv, a fixed set of behavior switches from the
  environment (`CI`, `COSMIC_COVERAGE`, `COSMIC_FENCE`,
  `COSMIC_FIXPOINT`, `COSMIC_BENCHMARK_MIN_SECONDS`), and the BYTES
  of every declared input — the
  source, the closure the rule already passes after `--deps`, and the
  tool stamps, which the compile line now carries after `--deps` too
  so the fence grants them and the key sees them. The key and the
  output's own hash land in `<out>.in`; a later invocation whose key
  and output both match restamps the output for make and spawns no
  child. Three rules bound it: only a line that declares inputs
  (`--deps` present) gets the skip, so the generator mini-graph's bare
  `compile` — which does its own scheduling and expects a dispatched
  compile to compile — never skips; only a recorded PASS
  short-circuits a `record`, so failures re-run and environment-gated
  skips never stick; and the output must hash to what the record
  names, so a corrupted artifact is rebuilt rather than trusted.
- **rejected:** hashing the whole environment (unbounded, and make
  itself already assumes env is inert — the fixed switch list makes
  the skip strictly more honest than the scheduler above it, not
  less); caching failing results (a red test deserves the re-run, and
  a skip's cause lives partly outside the key); skipping `capture`
  (its one caller declares no inputs, and a captured script may read
  anything); replacing make's scheduling outright with content
  addressing (D14 keeps make the graph executor; this composes with
  it instead).
- **consequences:** re-verifying an unchanged tree costs hashing, not
  compiling: a `touch` of every source, or a branch switch that
  changes few bytes, settles in seconds. A restored `o/` cache under a
  fresh checkout becomes usable, which is what CI caching needs
  (D18's `.in` records are self-verifying against the cached outputs:
  a record that does not match its output's bytes is ignored and the
  step runs). `.in` files are written plainly — nothing schedules on
  their mtime, and an always-fresh write makes them a probe for "the
  step really ran", which the tests use. The declared trust boundary:
  a `.in` beside its output stands for a prior run of this same
  project state; in CI that means trusting the cache's writer, which
  GitHub scopes to the branch that wrote it.
