A `db:pragma()` helper for cosmic.sqlite: reading a pragma today
takes `db:query_one("PRAGMA journal_mode")` plus knowing the result
column is named after the pragma, and setting one takes exec with
the value interpolated into the SQL string — the one place the
wrapper's own docs cannot say "always bind" because PRAGMA takes no
placeholders. The shape to refine in plan: `db:pragma(name)` returns
the current value; `db:pragma(name, value)` sets it and returns the
resulting value (pragmas echo or are re-readable), with the name
validated against a safe character set so the interpolation cannot
smuggle SQL. Precedent for per-connection pragmas is
cosmic/sqlite/defaults.tl, which hand-writes three of them and
would collapse onto the helper. Evidence of demand: the 2026-08-25
sqlite audit found pragma access is the only common operation with
no ergonomic path in the wrapper's preferred surface
(exec/query/query_one/transaction).
