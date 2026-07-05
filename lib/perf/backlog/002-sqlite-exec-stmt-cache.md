# 2. sqlite prepared-statement reuse

- status: done (2026-07-04)
- layer: cosmic
- scenario: sqlite_insert_delete_tx

- result: 679.87µs -> 234.32µs (-65.5%, comfortably beating the 20-50%
  hypothesis). `sqlite_point_query` also moved 13.34µs -> 11.98µs
  (-10.2%) though it goes through `db:query`/`db:query_one`, not the
  cached `db:exec` path — likely machine variance between the two runs
  rather than an effect of this change, noted rather than claimed.
- evidence: `db:exec(sql, ...)` (lib/cosmic/sqlite.tl) prepared,
  bound, and finalized a fresh statement on every parameterized call;
  the insert scenario paid 100 prepares per transaction for the same
  SQL string.
- fix: added `lib/cosmic/sqlite_stmt_cache.tl` (a new file, needed to
  keep sqlite.tl under the 500-line cap), a per-database cache of
  prepared statements keyed by SQL text used only by `db:exec`
  (per the "start with exec-only" risk note; `db:query*` still
  prepare/finalize per call — extended later by entry 8). reset +
  rebind on a cache hit; on SQLITE_SCHEMA the stale statement is
  dropped and re-prepared once; all cached statements are finalized in
  `db:close`.
- gotcha hit while implementing: the bootstrap compiler's `--compile`
  path (used to transpile .tl -> .lua, distinct from `--check-types`)
  misreports a zero-return-value method defined with colon-method
  sugar (`function self:m()`) inside a closure as returning 1 value.
  The existing codebase already works around this for `db.close` /
  `stmt.close` by assigning a plain function value
  (`self.m = function(self: T) ... end`) instead of colon sugar for
  zero-return methods; `close_all` here follows the same idiom.
- result detail: `bin/make perf-compare` from a clean re-baseline: 20
  scenarios, 0 regression, 2 faster, 18 ok.
