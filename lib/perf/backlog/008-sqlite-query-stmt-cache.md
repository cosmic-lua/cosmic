# 8. sqlite `db:query`/`db:query_one` prepared-statement reuse

- status: done (2026-07-04) — extends entry 2, which scoped the
  original cache to `db:exec` only
- layer: cosmic
- scenario: sqlite_point_query

- result: 8.87µs -> 6.32µs (-28.7% first pass, -29.2% on re-measure)
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
- result detail: `bin/make perf-compare` from a clean re-baseline,
  confirmed on a second re-measure: 21 scenarios, 0 regression, 1-2
  faster (`sqlite_point_query`), 19-20 ok.
