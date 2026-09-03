## Question

`6U2G_QaxW`'s spec ("lsqlite3: db_register_extension rejects
SQLITE_OK_LOAD_PERMANENTLY (appendvfs) as a failure") mandates a
regression case in `tool/lua/test_sqlite_register_extension.lua`
that asserts `db:register_extension("appendvfs")` (or "whichever
loadable unit is the first `SQLITE_OK_LOAD_PERMANENTLY`-returning
one landed") returns success. No such unit is registered in
`third_party/sqlite3/extensions.c` on current `origin/master`
(`833e4353`) — confirmed:

```
$ git show origin/master:third_party/sqlite3/extensions.c | sed -n '9,21p'
const struct SqliteExtension kSqliteExtensions[] = {
    {"decimal", sqlite3_decimal_init},
    {"fileio", sqlite3_fileio_init},
    {"ieee", sqlite3_ieee_init},
    {"regexp", sqlite3_regexp_init},
    {"series", sqlite3_series_init},
    {"sha", sqlite3_sha_init},
    {"shathree", sqlite3_shathree_init},
    {"sqlar", sqlite3_sqlar_init},
    {"stmtrand", sqlite3_stmtrand_init},
    {"uint", sqlite3_uint_init},
    {"zipfile", sqlite3_zipfile_init},
```

— batches 2 (`decimal fileio ieee sha shathree`, PR #370) and 3
(`sqlar stmtrand uint`, PR #371) landed; batch 1 (`appendvfs base64
base85 completion dbdata`) only got its extraction-RULE fixed
(`3InoAi3bSUyDIgESDOlE6CIBbi4`, accepted) — the rule fix's own spec
says landing batch 1 itself is a separate, not-yet-filed PR. Running
`6U2G_QaxW`'s own repro command against `origin/master` today:

```
$ ./o/tool/lua/lua.dbg -e '
local sqlite3 = require("cosmo.lsqlite3")
local db = assert(sqlite3.open_memory())
print(db:register_extension("appendvfs"))'
nil	extension 'appendvfs' is not available in this build	12
```

— not the `nil, "not an error", 256` `6U2G_QaxW`'s Evidence section
shows (that output came from a scratch build with all five batch-1
units wired in by hand, per that item's own Evidence paragraph).

A builder pulling `6U2G_QaxW` as specified today cannot write the
mandated regression case without either landing batch 1 first
(outside `6U2G_QaxW`'s stated file scope: `tool/net/lsqlite3.c` and
`tool/lua/test_sqlite_register_extension.lua` only) or adding a
throwaway registry entry to `third_party/sqlite3/extensions.c`
purely to exercise the test (also outside stated scope, and
`6U2G_QaxW`'s own Change text says "no new definition is needed").

Separately, `3InoAi3bSUyDIgESDOlE6CIBbi4`'s own Acceptance section
says the `lsqlite3.c` fix "is a prerequisite for landing batch 1,
not for answering this item's own question" — i.e. `6U2G_QaxW` was
filed to land BEFORE the batch-1 landing PR, so that PR's own gate
(`test_sqlite_register_extension.lua:173`) doesn't fail the moment
`appendvfs` is wired in. That is the reverse of what `6U2G_QaxW`'s
own regression-test requirement needs (a live registered
`appendvfs` to test against) — the two specs order each other in
opposite directions.

## Decision needed

How should this be sequenced? Candidates, not exhaustive:

a. Rescope `6U2G_QaxW`'s regression case to not require a live
   registered `SQLITE_OK_LOAD_PERMANENTLY` extension — e.g. drop the
   test requirement from this item entirely and instead require the
   batch-1 landing PR (not yet filed) to add the `appendvfs`-specific
   regression case itself, once `appendvfs` actually exists in the
   registry it can test.
b. File the batch-1 landing PR item now (using `3InoAi3b`'s accepted
   extraction-rule fix) and block it on `6U2G_QaxW` as originally
   intended, accepting that `6U2G_QaxW` lands with a narrower proof
   (e.g. a direct unit-level check of the `rc` mapping, not a
   registry round-trip) since no registered unit exists yet to drive
   the full round-trip test.
c. Something else the refiner sees that this evidence-gathering
   pass didn't.

## Non-goals

- Not re-litigating `3InoAi3b`'s extraction-rule fix itself (already
  accepted).
- Not itself the batch-1 landing PR's spec — that is filed separately
  once this question resolves the sequencing.

## Recommendation

Option (b). Measured on `origin/master` (`833e4353`): no registered
unit returns `SQLITE_OK_LOAD_PERMANENTLY` today —

```
$ git grep -n SQLITE_OK_LOAD_PERMANENTLY origin/master -- 'third_party/sqlite3/*.c' 'tool/net/lsqlite3.c' | grep -v 'sqlite3.c:\|shell.c:'
(no output — the only init using it is appendvfs, still inlined in shell.c)
$ git show origin/master:tool/net/lsqlite3.c | grep -n 'rc != SQLITE_OK'
1090:                if (rc != SQLITE_OK) {
1110:    if (rc != SQLITE_OK) {
```

so a registry round-trip test cannot exist before batch 1 lands, and
`test_sqlite_register_extension.lua:172-173` will assert-fail the
moment `appendvfs` is wired in unless the check is widened first.

Sequence: (1) respec `6U2G_QaxW` to widen both checks at
`lsqlite3.c:1090,1110` to `rc != SQLITE_OK && rc !=
SQLITE_OK_LOAD_PERMANENTLY`, with the existing register test unchanged
as the no-regression proof (all 11 registered units still succeed);
(2) file the batch-1 landing item (`appendvfs base64 base85 completion
dbdata`, using `3InoAi3b`'s accepted extraction rule) blocked on
`6U2G_QaxW`, and put the `appendvfs` round-trip assertion — `assert(
db:register_extension("appendvfs"))` — in THAT item's diff, where the
unit it tests exists.

Tradeoff: the widened check is unexercised for the `256` path until
batch 1 lands (a day or two), against (a)'s alternative of a C-boundary
contract fix riding inside an extraction PR, which AGENTS.md forbids
("a deliberate contract change … landed as its own change, never inside
an optimization") and which would also leave `6U2G_QaxW` open with no
diff of its own. A throwaway registry entry to unlock the test now is
outside `6U2G_QaxW`'s stated scope and would be deleted by batch 1.
