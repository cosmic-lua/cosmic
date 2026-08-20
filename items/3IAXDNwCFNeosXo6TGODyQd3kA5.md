## Goal

G5, via the cosmic.fuzz epic (3I1j7yQA, "Children" item 5): crash
isolation via `cosmic.child`, so a C-layer fault (a segfault or hang
inside a binding a property calls into — `re`, `json`, `compress`,
`zip`) is attributed to the input that caused it instead of killing
the whole fuzz run with no attribution.

## Change

Add crash isolation to `_fuzz/driver.tl` (215 lines measured 2026-08-20
via `wc -l _fuzz/driver.tl`, 285 lines of headroom under the 500-line
cap) with no changes to any `*_fuzz_test.tl` file — isolation is the
driver's default for every property, decided below from three spikes:

1. `cosmic.child.start`/`:wait(timeout_ms)` already distinguishes every
   outcome isolation needs, with no Result changes required. Spiked
   2026-08-20 (`cosmic.child` spawning a script that self-signals via
   `unix.kill(unix.getpid(), unix.SIGSEGV)`, exits 1, or hangs):
   `r.signal=11` on a crash, `r.code=1, r.signal=nil` on an ordinary
   exit, `nil, "timeout"` from `:wait(300)` on a hang, `r.code=0` on
   success. `r.stderr` is captured in every case.
2. Re-invoking the ALREADY-COMPILED test file directly (bare
   `cosmic <compiled.lua>`, bypassing `--make test`) is what makes
   isolation affordable, measured 2026-08-20 against
   `_fuzz/sse_fuzz_test.tl` (3 properties, 256 iterations each,
   default `FUZZ_ITERS`): `time o/bin/cosmic o/_fuzz/sse_fuzz_test.lua`
   is 107ms; `time o/bin/cosmic --make test _fuzz/sse_fuzz_test.tl` is
   5.29s (the converge/build/typecheck machinery, paid every
   invocation). Isolating at PROPERTY granularity — one subprocess per
   `driver.run` call, running that property's full iteration budget in
   the child, not one subprocess per iteration — costs roughly
   107ms/property, not 107ms/iteration: for the six `*_fuzz_test.tl`
   files' properties this adds about one second total, unconditionally
   safe to make the default. This settles the epic's open "opt-in vs.
   default" question: default, because the earlier framing measured
   the wrong granularity (per-iteration, where the cost really would
   have been prohibitive — over an hour at 256 iterations × ~15
   properties).
3. The re-exec argv is exactly `{arg[-1], arg[0]}` with no other
   elements to carry — measured 2026-08-20 by printing `arg[-5..2]`
   from a file run via `--make test`: `arg[-1]` is the cosmic binary's
   absolute path, `arg[0]` is the compiled test file's path relative to
   the repo root, and every other index (including where `--modules`
   would appear) is `nil` — `main.tl` consumes `--modules` before
   populating `arg`, and a compiled in-tree `.lua` file's requires
   already resolve without it (confirmed by the same bare-invocation
   spike in point 2 succeeding silently).

Design, to build in `_fuzz/driver.tl`:

- Add a module constant `DEFAULT_TIMEOUT_MS = 30000` and an `Options`
  field `timeout_ms: integer` (overrides it) — the wall-clock backstop
  for a hang when the VM instruction-hook is unavailable (budget
  already covers the hook-available case; see Non-goals).
- At the top of `run(opts)`, after resolving `seed`/`iters`/`budget` as
  today: read `env.get("FUZZ_ISOLATE")`.
  - If unset (the normal top-level call): build
    `argv = {arg[-1], arg[0]}`, spawn it via `child.start(argv, {env =
    <current env plus FUZZ_ISOLATE=opts.name, FUZZ_SEED=tostring(seed),
    FUZZ_ITERS=tostring(iters)>})`, `wait(opts.timeout_ms or
    DEFAULT_TIMEOUT_MS)`, and classify the `Result`:
    - `nil, "timeout"` → return `false, failure(opts.name, seed, iters,
      "", 0, ("hung: exceeded %dms"):format(opts.timeout_ms or
      DEFAULT_TIMEOUT_MS))` (iteration reported as the full budget,
      since a hang is not bisected — see Non-goals).
    - `r.signal` set → bisect: binary-search the smallest `k` in
      `[1, iters]` for which re-spawning the SAME argv with
      `FUZZ_ITERS=tostring(k)` (same `FUZZ_ISOLATE`/`FUZZ_SEED`,
      same timeout) still reports `r.signal` set (`~log2(iters)`
      respawns, e.g. 8 for the default 256). At the smallest such `k`,
      generate the input in-process (safe: `opts.gen` alone, no
      `opts.check`) via `opts.gen(source.new(rand.insecure_source(seed +
      k)))`, and return `false, failure(opts.name, seed, k, input,
      rec.draws, ("crashed: signal %d"):format(r.signal))`.
    - `r.code == 0` → return `true, <the success summary run() already
      formats today>`.
    - otherwise (`r.code ~= 0`, no signal — an ordinary property
      failure) → return `r.ok, r.stderr` (trimmed): the child ran the
      unchanged in-process loop below, which already builds the
      standard `failure()` message and reaches it via the same
      `check.truthy` path every property uses today, captured
      verbatim in `r.stderr`.
  - If set: if `env.get("FUZZ_ISOLATE") ~= opts.name`, return
    `true, (opts.name .. ": skipped (isolating a different property)")`
    immediately — no `gen`/`check` call — so every OTHER property in
    the same file becomes a no-op inside the child. If it matches,
    fall through to the existing loop body unchanged (this call IS the
    isolated child; do not spawn another).

## Non-goals

- No change to any `*_fuzz_test.tl` file — isolation is unconditional
  in `driver.tl` and needs no `Options.isolate` flag or per-file edit.
- No per-iteration subprocess spawning — isolation is per-PROPERTY
  (one child per `driver.run` call); only a confirmed crash triggers
  further (per-iteration) bisection respawns.
- No change to the existing VM instruction-budget hook
  (`arm_budget`/`disarm_budget`) — it remains the primary hang defense
  when the hook slot is free; `timeout_ms` is only the wall-clock
  backstop for when it is not (under the instrumented coverage stage).
- No minimization (`shrink.shrink`) of a crashing input — the crash
  case reports the raw input at the bisected iteration, unminimized.
  Shrinking a crash safely (running `shrink.shrink` itself inside
  isolation) is follow-up work, not this item's.
- No corpus persistence (`testdata/`, item 6) and no discard accounting
  (item 7) — separate children.
- No `cosmic.fuzz` publishing move (item 8, still blocked on the
  placement decision the epic's own spec has not yet settled).
- No change to `cosmic.child` or `cosmic/child/*.tl` — `Result` already
  carries every field this item needs (spiked above).

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _fuzz/driver_test.tl` passes, including three
  new tests: `test_a_crashing_check_is_attributed_to_its_iteration`
  (a `check` that self-signals SIGSEGV via `cosmo.unix.kill` on a
  specific drawn input; asserts the returned failure message contains
  `"crashed: signal 11"` and the exact iteration/seed that reproduces
  it), `test_a_hanging_check_is_reported_as_a_timeout` (a `check` that
  loops with the VM hook artificially disabled — reuse
  `test_the_budget_hook_is_cleared_between_runs`'s pattern for holding
  the hook slot — asserting the message contains `"hung: exceeded"`),
  and `test_other_properties_in_the_file_are_skipped_when_isolating`
  (sets `FUZZ_ISOLATE` to a name that does not match `opts.name` and
  asserts `run` returns `true` with a "skipped" message and never
  calls `gen`/`check`).
- `bin/cosmic --make test _fuzz` still passes and its wall time (the
  `wall:` line `--make test` prints) is under 30s — a loose ceiling
  confirming the per-property spawn did not regress the suite into the
  per-iteration cost this item rejected.

## Enablement

none needed — the design above is fully specified (exact env var
names, exact argv, exact message formats, exact bisection bound), and
the file-length and cast/lint conventions are existing gates
(`--make ci`) with headroom already measured above.
