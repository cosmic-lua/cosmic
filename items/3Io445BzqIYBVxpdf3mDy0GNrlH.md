## Evidence

Found by the builder of item `3If5s4hNeSCYCYLbOoyuYH1dq7T` (the
`value_type`/`column_type` accessors, PR #372) while adding sibling
accessors for the session/changeset iterator's old/new/conflict
values.

`tool/net/lsqlite3.c` carries roughly 600+ lines of SQLite session/
changeset/rebaser Lua-binding code (`liter_*`, `lsession_*`,
`lrebaser_*`, plus `seslib`/`reblib`/`itrlib` and related `dblib`
entries) guarded by `#ifdef SQLITE_ENABLE_SESSION`. `tool/net/BUILD.mk`
never defines `SQLITE_ENABLE_SESSION` for `lsqlite3.o` — only
`third_party/sqlite3`'s own library build defines it — confirmed by
`nm` on the built object (no `liter_*` symbols reachable) and by two
independent pieces of evidence already in the tree:

- `tool/lua/test_definitions_coverage.lua`'s own comment: "Session/
  changeset/rebaser support is compiled out ... not part of the
  shipped surface," which it explicitly strips before checking
  annotation coverage.
- `tool/lua/test_cosmo.lua` asserts `db.create_session == nil`.

So this code is permanently dead in every build this repo ships,
appears to be intentionally vendored/disabled rather than a
regression, and is large enough (and undocumented as dead in the
source itself, only in a test comment) that a new contributor keeps
discovering it and has to work out from scratch whether it is live —
exactly what happened while building `3If5s4hN`.

## Change

Decide and act on one of:

a. remove the dead `#ifdef SQLITE_ENABLE_SESSION` code from
   `lsqlite3.c` entirely (and any `definitions.lua` rows/test
   fixtures that only exist to accommodate it), since nothing in this
   repo's build ever compiles it in;
b. keep it (e.g. because a downstream consumer or a future build
   variant is expected to enable `SQLITE_ENABLE_SESSION`), but make
   its dead status discoverable from the source itself — a comment
   at the top of the guarded block pointing at why it's there and
   that it is not compiled in today, not just a test-file comment a
   contributor has to stumble onto.

Whichever is chosen, `test_definitions_coverage.lua`'s exclusion
comment and `test_cosmo.lua`'s assertion should stay consistent with
the decision.

## Non-goals

- No change to whether `SQLITE_ENABLE_SESSION` gets defined for any
  build variant — that's a build-configuration decision outside this
  item's scope, only the dead-code's discoverability/presence is in
  question.
