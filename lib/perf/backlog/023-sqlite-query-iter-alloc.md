# 23. sqlite db:query rebuilds iterator machinery on every call

- status: done (2026-07-05)
- layer: cosmic
- scenario: sqlite_point_query

- evidence: `sqlite_point_query` allocates 2.41KB/op for a single-row
  point query even though entries 2 and 8 already cache the prepared
  statement. Reading `stmt:rows()` (lib/cosmic/sqlite.tl:149-183):
  every `db:query` call builds, per call — a fresh iterator table, a
  fresh metatable, two fresh closures (`__call` and `err`), and a
  fresh `col_names` table populated by `get_name()` C calls on the
  first row. Only the row table itself is per-row payload; the rest
  is per-call overhead that is identical for every reuse of the same
  cached statement. `stmt:values()` (lines 185-209) has the same
  shape.
- hypothesis: cache the column-name array on the statement object
  (column names are a property of the prepared statement; invalidate
  alongside the SQLITE_SCHEMA re-prepare in the statement cache), and
  restructure so the iterator machinery isn't rebuilt per call —
  e.g. hoist the metatable to module level and carry per-iteration
  state (step_err, first_call) in the iterator table instead of
  closure upvalues. Expected: meaningful cut of the 2.41KB/op alloc
  and a few percent of the 7.98µs/op; `sqlite_scan_aggregate`
  (many rows per call) should show the col_names win too.
- correctness constraints: the reentrancy semantics from entry 8 must
  survive — a checked-out cached statement falls back to a throwaway
  statement, which must still get working (fresh or shared-static)
  iterator machinery; nested same-SQL queries are pinned by
  `test_same_sql_nested_query_reentrant`. The `iter.err` contract
  (returns the step error after the iterator drains) and the
  `stmt:close()`-on-completion behavior are pinned by existing
  tests.
- risk: medium — touches the query hot path and the iterator
  lifecycle; the existing sqlite test suite is thorough
  (sqlite_test, sqlite_advanced_test), which is the main safety net.
- result: done. The bigger cost than the iterator turned out to be
  `make_statement` itself: `db:query` built a full Statement object
  (~10 method closures + metatable) plus `Statement:rows()` plus the
  `make_query_iter` close-on-drain wrapper — three allocated layers —
  on every call, just to grab and drain one row. Collapsed all three
  into a single module-level iterator in a new
  `lib/cosmic/sqlite_row_iter.tl` (`make`/`query`): it resets, binds,
  steps the raw cached statement directly, resolves column names once
  on the first row, and releases the statement (via the cache's
  on_close, or finalize for a reentrant throwaway) when it drains.
  `db:query` now bypasses `make_statement` entirely; the public
  Statement API (`db:prepare`, `query_list`, `query_named`) is
  untouched, and since `db:query` was the only caller passing
  `on_close` to `make_statement`, that now-dead parameter was dropped.
  The `col_names`-per-call cost is paid once per iterator rather than
  cached across calls — measured alloc made the extra caching machinery
  unnecessary. sqlite.tl was at 500/500 lines, hence the helper module.
  Reentrancy (`test_same_sql_nested_query_reentrant`), the `iter:err()`
  post-drain contract, and close-on-completion all still pass.
  `perf-compare`:
    sqlite_point_query    7.44 µs/op ->  5.52 µs/op   -25.8%
      alloc               2.41 KB/op ->  1.08 KB/op   (-55%)
    sqlite_scan_aggregate alloc 2.30 KB/op -> 0.97 KB/op (col_names win)
  no regressions in the other 31 scenarios. `bin/make ci` green.
