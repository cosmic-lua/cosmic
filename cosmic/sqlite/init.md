# sqlite

 Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns.
 Wraps lsqlite3 with proper error returns and resource management.

 Prefer `db:exec()`, `db:query()`, `db:query_one()`, and
 `db:transaction()` over manual preparation, binding, and stepping.

     local sqlite = require("cosmic.sqlite")
     local db = sqlite.open(":memory:")
     db:exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
     db:exec("INSERT INTO users (name) VALUES (?)", "alice")
     for row in db:query("SELECT * FROM users WHERE name = ?", "alice") do
       print(row.id, row.name)
     end
     db:close()

 Binary values: wrap with `sqlite.blob(s)` to store with BLOB affinity
 (a bare Lua string always binds as TEXT). Opening applies sensible
 per-connection defaults — a 5000ms busy timeout, foreign_keys=ON,
 and WAL journal mode with synchronous=NORMAL; each has an
 `Options` field to tune or disable it.

## Types

### Rows

 Callable row iterator with an out-of-band error channel. Use it in a
 `for row in ... do` loop, then call `:err()` afterward to detect a step
 error (SQLITE_BUSY / CORRUPT / a RETURNING constraint failure) a for-loop
 cannot observe inline. `:err()` is nil only on a clean SQLITE_DONE.
 Draining the loop releases the underlying prepared statement. When
 iteration may stop early, call `:close()` (idempotent), or declare the
 iterator to-be-closed — `local rows <close> = db:query(...)` — so the
 statement is released on scope exit; garbage collection is the backstop.

```teal
local record Rows
  __call: function(self: Rows): {string: any}
  __close: function(self: Rows)
  --  Step error from iteration, or nil after a clean SQLITE_DONE.
  err: function(self: Rows): string | nil
  --  Release the underlying prepared statement early idempotent.
  close: function(self: Rows)
end
```

### Values

 Callable positional-value iterator, the `Statement:values()` counterpart
 to `Rows`. Same `:err()` contract.
 CAVEAT: a row whose FIRST column is SQL NULL returns `nil` as its first
 (and, to Lua, only visible) value, which a `for ... in` generic-for loop
 reads as end-of-iteration — the row is silently dropped, `:err()` stays
 nil, and remaining rows are never stepped. This is inherent to Lua's
 generic-for protocol (it stops at a nil first return) and the contract
 cannot change without breaking `local a, b, c = iter()` positional
 callers. Use `rows()` (or call the iterator directly, `local a, b, c =
 iter()`, one row at a time) when column 1 may be NULL.

```teal
local record Values
  __call: function(self: Values): any ...
  __close: function(self: Values)
  --  Step error from iteration, or nil after a clean SQLITE_DONE.
  err: function(self: Values): string | nil
  --  End iteration early (idempotent); also runs on scope exit via
  --  to-be-closed. Does not finalize the owning Statement — that is
  --  Statement:close()'s job, since the Statement may be reused.
  close: function(self: Values)
end
```

### Statement

 Statement handle with automatic cleanup.

```teal
local record Statement
  --  Bind parameters by position (resets the statement first). Handles
  --  trailing nils; `sqlite.blob()` wrappers bind with BLOB affinity.
  bind: function(self: Statement, ...: any): boolean, string
  --  Bind positional parameters from a list; the count comes from the
  --  SQL, so nil holes in the table bind as NULL.
  bind_list: function(self: Statement, values: {any}): boolean, string
  --  Bind :name placeholders from a key/value table (keys without the
  --  colon). `sqlite.blob()` wrappers are rejected — use positional
  --  binding for blobs.
  bind_named: function(self: Statement, params: {string: any}): boolean, string
  --  Callable iterator over result rows as {column: value} tables;
  --  check `:err()` after the loop for step errors.
  rows: function(self: Statement): Rows
  --  Callable iterator yielding each row's column values positionally;
  --  same `:err()` contract as rows(). CAVEAT: a NULL first column ends a
  --  `for` loop over this early (see Values above) -- prefer rows() when
  --  column 1 may be NULL.
  values: function(self: Statement): Values
  --  Step the statement to completion (for INSERT/UPDATE/DDL).
  exec: function(self: Statement): boolean, string
  --  Reset for re-execution; existing bindings are kept.
  reset: function(self: Statement)
  --  Number of result columns.
  columns: function(self: Statement): integer
  --  Name of result column n (1-indexed).
  column_name: function(self: Statement, n: integer): string
  --  Finalize the statement (idempotent); also runs on scope exit via
  --  to-be-closed.
  close: function(self: Statement)
end
```

### Database

 Database handle with automatic cleanup.

```teal
local record Database
  --  Compile sql into a reusable Statement for manual bind/iterate;
  --  prefer query()/exec() unless you need statement reuse.
  prepare: function(self: Database, sql: string): Statement | nil, string
  --  Run sql with positional `?` parameters and iterate result rows as
  --  {column: value} tables: `for row in db:query(...) do ... end`.
  --  Statements are cached per connection. Check `:err()` after the
  --  loop (or use `<close>`) per the Rows contract.
  query: function(self: Database, sql: string, ...: any): Rows | nil, string
  --  query() with parameters in a list, so nil holes bind as NULL.
  query_list: function(self: Database, sql: string, values: {any}): Rows | nil, string
  --  query() with :name placeholders bound from a key/value table.
  query_named: function(self: Database, sql: string, params: {string: any}): Rows | nil, string
  --  First matching row, or nil (with no error) when no row matches.
  --  The statement is always finalized, even when rows remain.
  query_one: function(self: Database, sql: string, ...: any): {string: any} | nil, string
  --  First column of the first row (nil + no error when no row matches
  --  or the value is SQL NULL); see cosmic.sqlite.extras.
  query_value: function(self: Database, sql: string, ...: any): any, string
  --  Execute sql with positional `?` parameters; use for statements
  --  that return no rows (INSERT/UPDATE/DELETE/DDL). Multi-statement
  --  sql runs only in the no-parameter form; with parameters it is
  --  REJECTED (sqlite would silently run just the first statement).
  exec: function(self: Database, sql: string, ...: any): boolean, string
  --  exec() with parameters in a list, so nil holes bind as NULL.
  exec_list: function(self: Database, sql: string, values: {any}): boolean, string
  --  exec() with :name placeholders bound from a key/value table.
  exec_named: function(self: Database, sql: string, params: {string: any}): boolean, string
  --  Run fn inside BEGIN IMMEDIATE .. COMMIT. Rolls back when fn
  --  raises, returns false, or returns nil plus an error; returning
  --  nothing (or true) commits. The callback is typed variadic
  --  (Teal cannot express optional returns), so a typed
  --  `function(db): boolean` rollback needs no cast; see
  --  cosmic.sqlite.extras.
  transaction: function(self: Database, fn: function(Database): any ...): boolean, string
  --  Run fn in a nestable savepoint with transaction's rollback rules;
  --  see cosmic.sqlite.extras.
  savepoint: function(self: Database, fn: function(Database): any ...): boolean, string
  --  rowid of the most recent successful INSERT (0 if closed).
  last_insert_rowid: function(self: Database): integer
  --  Rows modified by the most recent INSERT/UPDATE/DELETE (0 if closed).
  changes: function(self: Database): integer
  --  Close the database and its cached statements (idempotent); also
  --  runs on scope exit via to-be-closed. Live user-prepared
  --  Statements do not block it: the binding finalizes them during
  --  close. Returns false plus sqlite's message if the raw close ever
  --  fails — the handle is NOT marked closed then, so the database
  --  stays usable and a retry is a real retry, not a stale-flag
  --  success.
  close: function(self: Database): boolean, string
end
```

### sqlite

```teal
local record sqlite
  open: function(filename: string, opts?: Options): Database | nil, string
  blob: function(data: string): bind_mod.Blob
end
```

### Options

 Options for opening a database (see cosmic.sqlite.defaults).

alias of `cosmic.sqlite.defaults.Options` — field and method table: `cosmic --docs cosmic.sqlite.defaults.Options`

## Functions

### stmt:bind

```teal
function stmt:bind(...: any): boolean, string
```

 Bind parameters by position. Handles trailing nil values correctly
 (unlike varargs with table.unpack which drops them).
 Values wrapped with `sqlite.blob()` are bound with BLOB affinity.

### stmt:bind_list

```teal
function stmt:bind_list(values: {any}): boolean, string
```

 Bind parameters from a list table. The count is derived from the SQL,
 so nil values in the table are handled correctly without an explicit count.
 Values wrapped with `sqlite.blob()` are bound with BLOB affinity.

### stmt:bind_named

```teal
function stmt:bind_named(params: {string: any}): boolean, string
```

 Bind named parameters from a key/value table.
 SQL should use :name placeholders (e.g. ":foo", ":bar").
 Table keys are names without the colon prefix.
 `sqlite.blob()` wrappers are not supported here: the underlying
 bind_names call binds the wrapper table itself, silently losing BLOB
 affinity, so they are rejected — use positional binding for blobs.

### stmt:rows

```teal
function stmt:rows(): Rows
```

### stmt:values

```teal
function stmt:values(): Values
```

### stmt:exec

```teal
function stmt:exec(): boolean, string
```

### db:prepare

```teal
function db:prepare(sql: string): Statement | nil, string
```

### db:query

```teal
function db:query(sql: string, ...: any): Rows | nil, string
```

### db:exec

```teal
function db:exec(sql: string, ...: any): boolean, string
```

### db:query_one

```teal
function db:query_one(sql: string, ...: any): {string: any} | nil, string
```

 Return the first row matching a query, or nil if no rows match.
 Convenience method for single-row lookups.
 The underlying prepared statement is always finalized before returning,
 even when only the first row is consumed, preventing statement leaks.

### db:last_insert_rowid

```teal
function db:last_insert_rowid(): integer
```

### db:changes

```teal
function db:changes(): integer
```
