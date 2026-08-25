Three Params shapes bind NULL silently where the caller made a
mistake, measured 2026-08-25 at main a0c4ebd with the built binary:
a typo'd named key — `db:exec("INSERT INTO u VALUES (:name, :age)",
{nmae = "alice", age = 30})` — returns true and inserts name=NULL
(bind_named looks placeholders up in the table and a missing name
binds NULL, so an unconsumed key is invisible); a mixed table —
`{"bob", age = 44}` — dispatches positionally
(cosmic/sqlite/bind.tl:106-116) and silently drops the named keys,
inserting age=NULL; extra positional values beyond the placeholder
count are silently ignored. All three are the caller-bug shapes the
no-silent-bugs promise forbids returning true for. The fix: after a
named bind, refuse by name any provided key no placeholder consumed;
refuse a table with both an array part and string keys; refuse a
positional list longer than bind_parameter_count. The deliberate
nil-hole contract (a missing value binds NULL) stays — the
difference is a key or value the caller DID provide going nowhere.
Tests for each refusal beside the existing bind tests; the module
doc's Params paragraph states the refusals.
