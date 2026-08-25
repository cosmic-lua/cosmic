Statement methods on a closed Statement throw from library code,
violating the never-throw rule. Measured 2026-08-25 at main a0c4ebd:
after `stmt:close()`, `stmt:columns()` raises "calling 'columns' on
bad self" from /zip/cosmic/sqlite.lua, and `stmt:rows()` raises the
same from row_iter — only close() itself guards the closed flag
(cosmic/sqlite/init.tl:236-249); bind/bind_list/bind_named/rows/
exec/reset/columns/column_name all reach the finalized raw statement
unguarded. Database methods already do this right (every one checks
`closed` and returns an error). The fix: the same guard on every
Statement method; the infallible signatures move to fallible ones
(`columns(): integer | nil, string`) or the guard returns a zero
value with the contract documented — refine which in plan; the
right-to-break doctrine covers the signature change. Tests pin each
method's after-close behavior beside close_test.tl's existing cases.
