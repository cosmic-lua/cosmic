# Optimizing cosmic performance

this document is the operating manual for performance work on cosmic. it
defines a measurement-driven loop with hard gates, so optimization can be
executed mechanically — including by an agent — without risking functional
or style regressions. read it top to bottom once before changing anything.

## the harness in one minute

`lib/perf` benchmarks ~20 end-to-end scenarios (JSON, SQLite, HTTP client,
filesystem, hashing/codecs/compression, binary startup, Teal compilation).
every scenario validates its own output with a `check()` function, so a
change that makes a workload faster but wrong FAILS the benchmark.

```bash
bin/make perf                 # run all scenarios, write o/perf/current.json
bin/make perf-baseline        # snapshot results to o/perf/baseline.json
bin/make perf-compare         # re-run and fail on regression vs baseline
bin/make perf PERF_ONLY=json  # filter scenarios by Lua pattern
```

knobs: `PERF_SAMPLES` (default 5), `PERF_MIN_SECS` (default 0.15),
`PERF_THRESHOLD` (regression bar in percent, default 10), `PERF_BIN`
(which cosmic binary to measure).

report columns, per scenario:

```
sqlite_point_query    4537 x   12.62 µs/op  ± 0.7%  cpu/wall 1.00  alloc 2.36 KB
```

- `N x` iterations per sample; `µs/op` is the median across samples.
- `±%` spread across samples — treat deltas smaller than this as noise.
- `cpu/wall` — near 1.0 means CPU-bound (optimize algorithms/allocations);
  well below 1.0 means the time is in syscalls, I/O, or child processes.
- `alloc` — Lua-side KB allocated per op; high values mean GC pressure.

## the optimization loop

work ONE scenario (or one closely related group) at a time.

1. **baseline** on a quiet machine, from a clean tree:
   `git status` must be clean, then `bin/make perf-baseline`.
2. **pick a target** (see "finding opportunities" below). state a
   hypothesis: *"X is slow because Y; changing Z should cut ns/op by W%."*
3. **change the code.** smallest diff that tests the hypothesis. follow
   every repo convention (AGENTS.md): Teal, 2-space indent, ≤500-line
   files, `value, string` error returns, wrappers keep their documented
   behavior and error messages.
4. **gate 1 — correctness and style:** `bin/make ci` must pass
   (format + type check + tests + examples). the perf smoke test
   (`lib/perf/perf_test.tl`) runs every scenario end to end in CI, so a
   broken scenario check fails here too.
5. **gate 2 — performance:** `bin/make perf-compare`. it re-measures,
   compares against your baseline with a noise-aware bar
   (max of `PERF_THRESHOLD`, baseline spread, current spread), retries
   once on failure to filter machine noise, and exits nonzero if any
   scenario regressed, errored, or disappeared.
6. **decide.**
   - target scenario improved beyond its noise bar and nothing else
     regressed → keep it.
   - no measurable improvement, or anything else regressed → `git
     checkout` the change and record the failed hypothesis.
7. **commit**, quoting before/after numbers for the affected scenarios in
   the commit message (copy the `perf-compare` lines).

## hard rules (guardrails)

- NEVER delete, rename, or weaken a scenario or its `check()` to make a
  comparison pass. `perf-compare` treats missing scenarios as failures and
  the smoke test rejects scenarios without checks — do not work around
  either. renames belong in a separate, no-code-change commit that also
  re-baselines.
- NEVER commit `o/perf/*.json`. baselines are machine-specific and live
  only in your working `o/` directory.
- a wrapper's observable behavior (return values, error strings, edge
  cases like empty input) is part of its contract. optimizations that
  change behavior are rejected by `bin/make ci` / scenario checks — fix
  the approach, not the test.
- one hypothesis per commit. if `bin/make ci` fails, you are done with
  that hypothesis until it passes; never trade correctness for speed.
- benchmarks live under `lib/perf/bench/` and use `cosmic.*` modules only
  (never raw `cosmo.*`) — they measure what users experience.

## finding opportunities

check the hypothesis backlog below first — it holds vetted, evidence-backed
starting points. to find new ones, read `bin/make perf` output and look for:

- **implementation mismatches between siblings.** example found during
  harness bring-up: `codec_hex_roundtrip_64k` ran ~17.6ms while
  `codec_base64_roundtrip_64k` ran ~2.1ms on the same input. cause:
  `codec.decode_hex` is a pure-Lua `gsub` with a per-byte-pair callback
  plus two validation scans, while a `cosmo.DecodeHex` C binding exists
  (`lib/types/cosmo.d.tl`). preserving the documented error returns while
  delegating the hot path is the archetypal cosmic-layer win.
- **high `alloc` with high ns/op** — allocation-heavy Lua (string
  concatenation in loops, per-item closures). e.g. `json_decode_large`
  allocates ~375KB/op; how much is unavoidable C-side table building vs
  wrapper overhead is a question worth answering.
- **`cpu/wall ≈ 1.0` on I/O scenarios** — a workload you expected to be
  I/O-bound but that burns CPU (e.g. rebuilding strings per chunk).
- **pairs of scenarios that bracket a layer.** `http_fetch_get` vs
  `http_tcp_roundtrip` isolates the fetch-wrapper overhead from raw
  socket cost; `startup_run_teal` vs `startup_run_lua` isolates the Teal
  loader (~13ms today) from runtime boot (~14.5ms).
- **profile a single scenario** by bisection: `bin/make perf
  PERF_ONLY=<name>` is cheap; temporarily splitting a scenario's fn into
  narrower scenarios in a scratch bench file localizes the cost. delete
  scratch scenarios before committing.

if a workload you want to optimize has no scenario, add one FIRST (in a
`lib/perf/bench/*_bench.tl` module, with a real `check()`), baseline it,
then optimize.

## hypothesis backlog

concrete, evidence-backed starting points, ordered by expected
value-for-effort. numbers are from harness bring-up on the CI container
(2026-07); re-baseline on your machine before trusting them.

work the backlog like this: pick ONE entry, run the loop above, then
update the entry in the same commit — `done` (commit hash + before/after
numbers) or `rejected` (measured numbers + why the hypothesis was wrong).
rejected entries stay in the file; they save the next agent from
re-testing a dead end. add new entries as `open` when a report line or
code read suggests one.

1. **hex decode via the C binding** — done (2026-07-04)
   - scenario: `codec_hex_roundtrip_64k`: 17.53ms -> 2.16ms (-87.7%
     first pass, -88.0% on re-measure)
   - evidence: `codec.decode_hex` (lib/cosmic/codec.tl) was a pure-Lua
     `gsub("(%x%x)", callback)` — one closure call per byte pair, ~32k
     for 64KB — plus two full-string validation scans. `cosmo.DecodeHex`
     exists (lib/types/cosmo.d.tl:130) and was unused.
   - fix: kept the existing Lua-side even-length and hex-character
     validation (so the documented `value, string` error returns and
     messages are unchanged — `cosmo.DecodeHex` raises a Lua error on
     odd length / non-hex input rather than returning nil+err, so
     validation must run first), then delegated the actual byte
     conversion to `cosmo.DecodeHex` instead of the gsub callback.
   - result: no other scenario regressed (`bin/make perf-compare`: 20
     scenarios, 0 regression, 1 faster, 19 ok after a clean re-measure;
     an initial run flagged an unrelated `startup_*` scenario that
     didn't reproduce and isn't touched by this change).

2. **sqlite prepared-statement reuse** — done (2026-07-04)
   - scenario: `sqlite_insert_delete_tx`: 679.87µs -> 234.32µs (-65.5%,
     comfortably beating the 20-50% hypothesis). `sqlite_point_query`
     also moved 13.34µs -> 11.98µs (-10.2%) though it goes through
     `db:query`/`db:query_one`, not the cached `db:exec` path — likely
     machine variance between the two runs rather than an effect of
     this change, noted rather than claimed.
   - evidence: `db:exec(sql, ...)` (lib/cosmic/sqlite.tl) prepared,
     bound, and finalized a fresh statement on every parameterized call;
     the insert scenario paid 100 prepares per transaction for the same
     SQL string.
   - fix: added `lib/cosmic/sqlite_stmt_cache.tl` (a new file, needed to
     keep sqlite.tl under the 500-line cap), a per-database cache of
     prepared statements keyed by SQL text used only by `db:exec`
     (per the "start with exec-only" risk note; `db:query*` still
     prepare/finalize per call). reset + rebind on a cache hit; on
     SQLITE_SCHEMA the stale statement is dropped and re-prepared once;
     all cached statements are finalized in `db:close`.
   - gotcha hit while implementing: the bootstrap compiler's `--compile`
     path (used to transpile .tl -> .lua, distinct from `--check-types`)
     misreports a zero-return-value method defined with colon-method
     sugar (`function self:m()`) inside a closure as returning 1 value.
     The existing codebase already works around this for `db.close` /
     `stmt.close` by assigning a plain function value
     (`self.m = function(self: T) ... end`) instead of colon sugar for
     zero-return methods; `close_all` here follows the same idiom.
   - result: `bin/make perf-compare` from a clean re-baseline: 20
     scenarios, 0 regression, 2 faster, 18 ok.

3. **startup: Teal loader cost** — step (a) done (2026-07-04), step (b) open
   - scenario: `startup_run_lua`: 19.20ms -> 8.40ms..5.72ms across two
     re-measures (-56% to -70%). the whole `.lua`-vs-`.tl` gap this entry
     named turned out to be almost entirely step (a), not compilation
     itself: `startup_run_teal`/`startup_compile_teal` were essentially
     unchanged (still pay for loading the compiler, which they still need).
   - evidence: `main.tl` called `require("tl").loader()` unconditionally
     at the top of EVERY invocation — even `--version`, `-e`, or running a
     plain `.lua` script — forcing Lua to load and execute the ~15k-line
     compiled `tl.lua` module every time.
   - fix (step a): replaced the eager `require("tl").loader()` with a
     lazy searcher installed directly at the end of `package.searchers`.
     It only calls `require("tl")` (and installs the real
     `tl_package_loader`, replacing itself) the first time some
     `require()` call isn't resolved by an earlier searcher — i.e. the
     first time a `.tl`-only module is actually needed. Verified against
     `lib/cosmic/tl_loader_test.tl` (which asserts the searcher is present
     and not at position 2) and manually: plain `.lua` scripts, `-e`, and
     requiring a `.tl`-only module (falling back through the lazy
     searcher) all still work.
   - step (b) (compiled-output caching keyed by mtime/hash, so repeat runs
     of an unchanged `.tl` script cost `.lua` startup) is unexplored;
     `startup_run_teal`/`startup_compile_teal` remain open for it.
   - risk note for step (a) that mattered in practice: the return type of
     a `package.searchers` element is itself a function type
     (`function(string): (function(string?, any?): any, any)`); writing
     that nested function-return-type inline as an explicit annotation
     compiles and type-checks fine but trips a bootstrap-compiler
     formatter bug (mis-indents everything after the declaration). Worked
     around by declaring the wrapper's return type as plain `any, any`
     and destructuring the real searcher's result into typed locals
     before returning them, instead of returning the call expression
     directly.
   - result: `bin/make perf-compare` from a clean re-baseline, confirmed
     on a second re-measure: 20 scenarios, 0 regression, 1-2 faster
     (`startup_run_lua`), 18-19 ok.

4. **startup: runtime boot floor (cosmopolitan side)** — open, floor moved
   - scenario: `startup_run_lua` was ~14.5-19ms for `print()`; after
     entry 3's step (a) fix it measured 5.7-8.4ms across two runs on a
     noisy machine (re-baseline before trusting an absolute number here).
   - evidence: eager `require("tl")` (entry 3) turned out to be the
     dominant cost this entry originally attributed to "eager cosmic-side
     module loading in main.tl" generally; with it gone, remaining floor
     is the APE loader + zip filesystem + Lua init + cosmic's other
     top-level `require`s (getopt, args, help, main_handlers, etc.).
   - hypothesis: deferring the remaining dispatch-only imports (e.g.
     `help`, only used for `--help`) trims a small additional amount; the
     rest is cosmos-side (zip central-directory scan, stdlib init) —
     measure with the pinned raw cosmos `lua` binary as `PERF_BIN`
     denominator before touching whilp/cosmopolitan.
   - risk: low for any further import-deferral; cosmopolitan-side work
     follows the "optimizing the cosmo/cosmopolitan layer" section.

5. **fs.walk per-entry cost** — done for `files()`/`collect_all()`
     (2026-07-04); `walk()`/`collect()` unchanged (see below)
   - binding check: `unix.Dir:read()` (`lib/types/cosmo/unix.d.tl:157`)
     already returns `string, number, number, number` — name, `kind`
     (d_type: `DT_DIR`/`DT_REG`/`DT_LNK`/.../`DT_UNKNOWN`), ino, off —
     but `fs_walk.tl`'s internal `WalkDirHandle` record only declared a
     single `string` return, discarding `kind`.
   - key finding that narrowed the hypothesis: `walk()` (and `collect()`,
     which is implemented on top of `walk()`) hands every visitor a full
     `WalkStat`, per its documented contract — so those two can NOT skip
     the stat(2) call without changing observable behavior. Only
     `collect_all()` and `files()` have their own private traversal loops
     that never expose `st` to a caller, so only those two got the d_type
     fast path. `walk()`/`collect()` are unchanged; a future pass could
     revisit them with an explicitly lazy-stat visitor API, but that's a
     bigger, contract-changing effort out of scope here.
   - fix: `WalkDirHandle.read` now returns the `kind` too. In
     `collect_all()`/`files()`, `kind == DT_DIR` recurses (or pushes)
     without stat (d_type never follows symlinks, so this still can't
     recurse into a symlinked dir — a symlink reports `DT_LNK`, the same
     cycle prevention `AT_SYMLINK_NOFOLLOW` stat gave before); any other
     definite (non-`DT_UNKNOWN`) kind skips stat too, since `files()`
     never needed stat data beyond "not a directory" and `collect_all()`
     only stores `DT_REG` entries (for which stat is still needed, for
     the mode bits); `DT_UNKNOWN` falls back to the original stat-based
     check unchanged, for filesystems that don't expose d_type.
   - added a new scenario, `fs_files_tree` (iterates `fs.files()` over
     the existing seeded tree matching `*.txt`), since `files()` and
     `collect_all()` had no benchmark coverage before this — `files()`
     is the one where a file-heavy tree pays for zero stat(2) calls
     instead of one per entry, so it shows the win most clearly.
   - result: `fs_files_tree` 415.81µs -> 187.31µs (-55.0%, confirmed
     -56.7% on re-measure). `bin/make perf-compare` both times: 21
     scenarios, 0 regression, 1 faster, 20 ok. `fs_walk_tree`/`fs_stat_tree`
     unaffected (within noise), as expected since `walk()` didn't change.
     verified against `lib/cosmic/fs_walk_test.tl`'s existing symlink-cycle
     tests for `collect_all()` and `files()`, which pass unchanged.

6. **string.split micro-costs** — done (2026-07-04)
   - scenario: `string_split_csv`: 38.82µs -> 32.20µs (-17.0%, matching
     the 10-20% hypothesis)
   - evidence: implementation already used plain `find`; remaining cost
     was `table.insert` (a C call resolving `#result` each time) and one
     `sub` per field.
   - fix: replaced every `table.insert(result, ...)` with an explicit
     `n = n + 1; result[n] = ...` counter, in both the empty-separator
     (per-character) and normal-separator branches.
   - result: `bin/make perf-compare`: 21 scenarios, 0 regression, 1
     faster, 20 ok. real user impact is small (this was a warm-up-scale
     item per the original hypothesis), but the win landed exactly where
     predicted with zero risk.

7. **json decode allocation pressure** — rejected for now (2026-07)
   - scenario: `json_decode_large` (~1.3ms/op, ~375KB allocated per op)
   - finding: the wrapper (lib/cosmic/json.tl) is a two-line delegation
     to `cosmo.DecodeJson`; the allocation is the decoded table graph
     itself (1000 records × maps/arrays), which is the workload's
     output, not overhead. no cosmic-layer fix exists; a
     cosmopolitan-side arena would change object lifetimes. revisit only
     if a scenario shows GC pauses dominating a real workload.

8. **sqlite `db:query`/`db:query_one` prepared-statement reuse** — done
     (2026-07-04); extends entry 2, which scoped the original cache to
     `db:exec` only
   - scenario: `sqlite_point_query`: 8.87µs -> 6.32µs (-28.7% first
     pass, -29.2% on re-measure)
   - evidence: `db:query(sql, ...)` (lib/cosmic/sqlite.tl) called
     `self:prepare(sql)` on every call — a fresh prepare/finalize per
     query even for identical repeated SQL text. `sqlite_point_query`
     and `sqlite_scan_aggregate` (via `db:query_one`) both hit this.
   - fix: added `checkout`/an implicit checkin (a returned closure) to
     `lib/cosmic/sqlite_stmt_cache.tl`, in a *separate* cache/table from
     `db:exec`'s (so the two call kinds can never contend for the same
     slot even if the same SQL text were somehow used for both). Unlike
     `exec`, a query's statement stays alive for its `Rows` iterator's
     whole lifetime, so a naive single-slot-by-SQL-text cache would
     corrupt a nested/interleaved query for the *same* SQL text (e.g. a
     self-join pattern querying the same table twice, one query per
     loop level). `checkout()` hands out the shared cached statement
     only when it isn't already checked out; otherwise it prepares a
     throwaway statement for that call, exactly like the old
     uncached behavior. `make_statement`'s `close()` takes an optional
     `on_close` callback (checkin instead of finalize) so `db:query`
     didn't need its own iterator-wrapping code — `make_query_iter`
     already calls `stmt:close()` on completion, unchanged.
   - added `test_same_sql_nested_query_reentrant` to
     `lib/cosmic/sqlite_advanced_test.tl` (the existing
     `test_nested_queries` only nests *different* SQL text, which never
     touches the same cache slot) — queries the same table with the
     same SQL in a nested loop, then confirms the cache slot still
     works after both iterators drain.
   - gotcha hit while implementing: writing a function type as one
     return value in a multi-return signature — even as a named `local
     type X = function(...)` alias rather than an inline literal — trips
     the same bootstrap-compiler formatter bug found in the Teal-loader
     round (mis-indents every line after the declaration). This turned
     out to already be baked into the committed `lib/cosmic/init.tl`
     (its `local type MainFn = function(...)` line has the identical
     shift), so the fix was to accept the formatter's own output
     verbatim as the file content, matching that existing precedent,
     rather than fight it.
   - result: `bin/make perf-compare` from a clean re-baseline, confirmed
     on a second re-measure: 21 scenarios, 0 regression, 1-2 faster
     (`sqlite_point_query`), 19-20 ok.

## optimizing the cosmo/cosmopolitan layer end to end

scenarios call `cosmic.*` wrappers, which call the `cosmo.*` C bindings
from the pinned cosmos binary, so C-layer changes show up in the same
numbers. `startup_*` scenarios additionally cover the APE loader, zip
filesystem, and Lua boot — the parts that only change when the
cosmopolitan pin changes.

to evaluate a cosmopolitan-side change (in whilp/cosmopolitan):

1. baseline with the current pin: `bin/make perf-baseline`.
2. build or fetch a cosmos release with the change and produce a cosmic
   binary from it: bump `3p/cosmos/version.lua` (url + sha256), run
   `bin/make regen-types && bin/make build` and fix any wrapper breakage
   (see AGENTS.md "Type Generation").
3. `bin/make perf-compare` now measures old pin vs new pin with identical
   scenarios. `PERF_BIN=/path/to/other/cosmic bin/make perf` measures any
   prebuilt binary without touching the pin; results record the binary in
   `meta.bin`.

## measurement discipline

- machine noise is real: nothing else heavy runs during measurement;
  baseline and comparison run on the same machine, same power state.
- the compare bar auto-widens to each scenario's observed spread, and
  `perf-compare` re-measures once before failing — but if results still
  look inconsistent, re-run `perf-compare`; a genuine change reproduces
  in the same direction every time.
- prefer default `PERF_SAMPLES`/`PERF_MIN_SECS` for accept/reject
  decisions; use lower values only for quick scouting.
- scenarios must be stationary: an op must not get slower the more often
  it runs (growing tables, leaking fds, write-churn on overlay
  filesystems). the insert scenario deletes inside its transaction and
  fs scenarios stick to stable operations for exactly this reason.
