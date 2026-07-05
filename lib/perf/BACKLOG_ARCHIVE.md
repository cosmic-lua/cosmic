# Performance hypothesis backlog — archive (entries 1-8)

Older entries moved out of `lib/perf/BACKLOG.md` purely because that file
kept growing past the repo's 500-line-per-file cap — the split carries no
other meaning. See `lib/perf/OPTIMIZE.md` for the operating manual and
`lib/perf/BACKLOG.md` for the active log (entry 9 onward).

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

3. **startup: Teal loader cost** — step (a) and step (b) both done (2026-07-04)
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
   - result (step a): `bin/make perf-compare` from a clean re-baseline,
     confirmed on a second re-measure: 20 scenarios, 0 regression, 1-2
     faster (`startup_run_lua`), 18-19 ok.
   - fix (step b): added `lib/cosmic/script_cache.tl`, a compiled-output
     cache used only by `load_script_file` (`main_handlers.tl`) — i.e.
     only `cosmic script.tl`, not `--compile`/`--check-types`/etc., which
     call `cosmic.teal` directly and are unaffected. Keyed on
     `script_path .. content .. build_id` (the running cosmic binary's
     version string, so a different build — possibly a different
     embedded Teal compiler — never reuses another build's cached
     output), hashed with `cosmic.hash.sha256_hex`. **Deliberately
     content-hashed, not mtime-based**: an mtime key (the original
     hypothesis's wording) risks a false cache hit if a script is
     rewritten within one filesystem mtime tick (coarse on some
     filesystems) — reading the small source file to hash it is cheap
     next to a full Teal compile, so there's no real reason to accept
     that risk. A failed compile (type or syntax error) is never cached,
     so error messages always reflect a fresh compile. Best-effort
     throughout: any cache read/write failure (missing dir, no write
     permission, a race with another process) is treated as a miss/no-op,
     never a hard error.
   - added `test_script_cache_reuse_and_invalidation` to
     `lib/cosmic/script_test.tl`: runs a `.tl` script twice (same
     content, expects a cache hit the second time — verified indirectly,
     since correctness rather than hit/miss is what's asserted), then
     overwrites it with different content and confirms the new output
     wins (cache invalidation via content hash, not stale reuse).
   - result (step b): `startup_run_teal` 27.91ms -> 6.55ms first pass
     (-76.5%), 7.59ms on re-measure (-72.8%) — now close to
     `startup_run_lua`'s own floor, as step (b)'s original hypothesis
     predicted. `startup_compile_teal` unaffected (within noise) both
     times, as expected since `--compile` bypasses the cache entirely.
     `bin/make perf-compare` both times: 22 scenarios, 0 regression,
     1 faster, 21 ok.

4. **startup: runtime boot floor (cosmopolitan side)** — import-deferral
     step rejected (2026-07-04); cosmopolitan-side work still open
   - scenario: `startup_run_lua` was ~14.5-19ms for `print()`; after
     entry 3's step (a) fix it measured 5.7-8.4ms across two runs on a
     noisy machine (re-baseline before trusting an absolute number here).
   - evidence: eager `require("tl")` (entry 3) turned out to be the
     dominant cost this entry originally attributed to "eager cosmic-side
     module loading in main.tl" generally; with it gone, remaining floor
     is the APE loader + zip filesystem + Lua init + cosmic's other
     top-level `require`s (getopt, args, help, main_handlers, etc.).
   - attempt: deferred `local help = require("cosmic.help")` in main.tl
     to inside the `if opts.help then` branch (the only place it's
     used), matching the exact "e.g. `help`" example this entry named.
   - finding: `bin/make perf-compare` from a clean re-baseline showed
     `startup_run_lua` +4.0% — noise (±10.0% bar), not a real
     regression, but also not a measurable improvement. A quick manual
     A/B first (alternating `COSMIC_NO_REQUIRE_HINTS=1` runs of a
     trivial `.lua` script, ~30-50 iterations each way) had already shown
     the same thing: differences bounced both directions across repeats,
     never landing consistently on one side. `getopt`/`args`/
     `main_handlers` can't be deferred the same way (needed on every
     invocation to parse args and dispatch), so there wasn't a second
     candidate to combine with `help` for a larger, clearer effect.
     Reverted the change (`git checkout -- lib/cosmic/main.tl`) since it
     had no measurable win to justify keeping.
   - revised hypothesis: this entry's `startup_run_lua` floor (now
     single-digit ms, cpu/wall ~0.2-0.3 per recent baselines — mostly
     NOT CPU) is dominated by something below the Lua-require level
     entirely: the APE loader, zip filesystem init, or Lua runtime boot.
     Further wins here belong to the "optimizing the cosmo/cosmopolitan
     layer" section (in `OPTIMIZE.md`; measure against the pinned raw
     cosmos `lua` binary via `PERF_BIN` first), not to more main.tl
     import shuffling.
   - risk: n/a for the rejected step; cosmopolitan-side work follows the
     "optimizing the cosmo/cosmopolitan layer" section in `OPTIMIZE.md`.

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
