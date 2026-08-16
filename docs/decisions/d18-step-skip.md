# D18 — expensive recipe steps skip on input bytes, not just on mtime

- **date:** 2026-08
- **status:** amended 2026-08 (declared env)
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
  `COSMIC_FIXPOINT`, `COSMIC_BENCHMARK_MIN_MS`), and the BYTES
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
- **amended 2026-08 (declared reads):** the key hashed only the
  step's DECLARED inputs, and a test's declarations were its imports —
  but the fence deliberately grants tests read access to the whole
  project, precisely because ratchet tests read things no import names
  (`_build/docs_test` reads `docs/decisions/`, `_build/workflows_test`
  reads `.github/workflows`). A test in that gap could be replayed
  stale: edit the ratchet's subject and the cached verdict stood. The
  fix is a declaration channel: a `--- reads: <path>` doc-comment line
  in a test names a non-import input (a directory declares every file
  under it, expanded at scan time so the key sees bytes and make sees
  files); the declaration joins the test's `deps_*` closure in
  `o/project.mk`, which makes it a prerequisite (mtime scheduling), a
  content-key input, and a fence grant in one stroke. A declaration
  naming a missing path refuses the build — an input that cannot be
  hashed is a declaration gone stale. Remaining, stated: reads of
  `o/`-resident artifacts (e.g. `_types/gentl_test` reading the
  unpacked pinned tl source) stay undeclared — they change only on a
  pin bump, which the import of the pin already keys — and the fence's
  whole-project read grant for tests is unchanged; narrowing it to
  imports + declared reads is the eventual follow-up that would turn
  any remaining undeclared read into a loud denial instead of silent
  staleness.
- **amended 2026-08 (declared env):** the same gap existed one layer
  down, for an environment VALUE instead of a file: nothing in the
  tree depends on `FUZZ_ITERS` or `FUZZ_SEED`, so a run that only
  changed one of them left every prerequisite of a `.got` unmoved, and
  even a forced recipe hit the content key's fixed `ENV_SWITCHES` list,
  which the two variables are not on — a run genuinely meant to fuzz
  deeper replayed the last cached PASS instead. The fix mirrors the
  declared-reads channel exactly: a `--- env: <NAME> <NAME> ...`
  doc-comment line (`_make.imports.env_of_file`) names environment
  variables a test reads; the build stamps their CURRENT values into a
  hashed file (`o/.env/<stem>.env`, `_make/envstamp.tl`) and that stamp
  joins `deps_<stem>`, exactly like a declared read path — a
  prerequisite (mtime scheduling), a content-key input (its bytes ride
  in via `--deps`), and a fence grant, in one stroke. The file stores
  the HASH of `NAME=value` (or bare `NAME` for an unset variable — unset
  and empty must hash differently, or a step branching on "is this set
  at all" could not observe the difference) rather than the plaintext
  value, so `o/` never collects a secret a declared name happens to
  name. A declared name refuses the build when it fails the identifier
  pattern or collides with `ENV_SWITCHES` — the latter is already in
  every step key, and `COSMIC_COVERAGE` specifically is rewritten
  per-lane by the runner before the child ever sees it
  (`_tool/testrun.tl:54-68`), so a declaration would stamp a value the
  child does not run with. "Hash the whole environment" stays rejected
  for the same reason it was rejected the first time: make already
  assumes the environment is inert outside the fixed switch list, and a
  declaration channel is strictly more honest than widening that
  assumption, not less. Undeclared env is unchanged: it caches exactly
  as before, which is the point — only a name a test actually declares
  can move its stamp.
