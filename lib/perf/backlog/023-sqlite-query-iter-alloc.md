# 23. sqlite db:query rebuilds iterator machinery on every call

- status: open
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
