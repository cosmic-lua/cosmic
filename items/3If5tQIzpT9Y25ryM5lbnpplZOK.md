## Change

Give `cosmic.sqlite.open` an `extensions` option whose meaning is *ensure each named
capability is available on this connection, or fail*.

```teal
local db, err = sqlite.open(path, {extensions = {"series", "fts5"}})
```

### One meaning, two mechanisms

SQLite capabilities arrive by two different routes, and the caller must not have to
know which:

- **registered per connection** via an init function — the `ext/misc` extensions
  (`series`, `regexp`, `sha3`, `base64`, `fileio`, `zipfile`, …);
- **compiled in** via a build flag — FTS5, RTREE, GEOPOLY, dbstat, JSON1, math —
  present on every connection, ungatable at open.

A list that silently ignored the second class would read as an exhaustive
declaration and not be one: a caller omitting `"fts5"` still gets FTS5, and a caller
naming it gets no error, no effect, and no way to tell. So the option registers what
is registerable, **verifies** what is compiled in, and returns `nil, msg` for
anything this build cannot provide. The caller asks for a capability, never for a
mechanism. It also buys a portability check for free: a binary built without FTS5
fails at `open` instead of at the first `CREATE VIRTUAL TABLE`.

### The vocabulary is generated, not written here

Extension names come from the C registry's `---@alias` in `definitions.lua`, which
`_types/gentype.tl` renders as a Teal enum (`_types/gentype_alias_test.tl` asserts
literal-union aliases become `local enum … end`). So `extensions` is typed as that
enum, a misspelling is a **type error at `--check types`**, and there is no list in
`cosmic/` to drift from what the binary actually carries.

### The default is empty, and that is a security decision

`open(path)` with no options registers nothing. The floor is still core plus
whatever is compiled in — the option controls registration and assertion, never the
floor — but the registerable surface becomes exactly what the call site names.

The reason it is empty rather than curated: `fileio` provides `readfile()`,
`writefile()` and `fsdir()`. Filesystem read and write reachable from any SQL
string, including one built from untrusted input, in a project whose containment
goal (G2) is that capabilities are granted rather than assumed. An empty default is
the only one under which that cannot arrive by accident.

### The break, stated

`zipfile` is registered unconditionally today and `cosmic/sqlite/zipfile_test.tl`
asserts it on every open:

```teal
local row = db:query_one(
  "SELECT name FROM pragma_module_list WHERE name = 'zipfile'")
assert(row ~= nil, "sqlite did not register the zipfile module …")
```

Under an empty default that is false. This item takes the break
([D10](docs/decisions/d10-right-to-break.md)): the test moves to opening with
`{extensions = {"zipfile"}}`, `cosmic/sqlite/zipfile_example.tl` and the artifacts
guide gain the option, and the release notes name it. Callers that used `zipfile`
without asking now get a clear `no such table` at first use — so the guide change is
the migration, and it must be in the same PR.

### Files

- `cosmic/sqlite/init.tl` — the `extensions` option on `open`, ensure-or-fail.
- `cosmic/sqlite/types.tl` — `Options` gains the field, typed as the generated enum.
- `cosmic/sqlite/zipfile_test.tl`, `zipfile_example.tl`, `docs/guides/**` — the
  migration.
- A test per outcome: registered, already-present-compile-time, and refused.

## Non-goals

- No default set, curated or otherwise.
- No C changes; this consumes the registration entry point.
- No UDF work.
