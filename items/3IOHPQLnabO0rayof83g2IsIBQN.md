Two observed sqlite behaviors are undocumented, and a doc statement
that exists nowhere cannot be CI-verified (the promise is documented
behavior IS verified behavior). Measured 2026-08-25 at main a0c4ebd:
(1) duplicate column names in a join collapse silently — `SELECT
x.id, x.v, y.id, y.v FROM x, y` yields a row with only {id, v} and
the LAST duplicate wins, because rows are {column: value} tables
keyed by name (cosmic/sqlite/row_iter.tl:79-83); the doc for
query/Rows never says so, and the fix for a caller (alias the
columns) is one clause. (2) a boolean binds as an integer — `true`
stores as 1 with typeof(v) = "integer" and reads back as the number
1, not a boolean; the Params/bind docs never state the affinity.
Both land as doc-comment clauses on query/Rows and on Params/blob
in cosmic/sqlite (served by --docs sqlite), each with an example or
test asserting the stated behavior so the claim is executable.
