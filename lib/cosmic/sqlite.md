# sqlite

 Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns.
 Wraps lsqlite3 with proper error returns and resource management.

 This module provides a high-level API over lsqlite3. Prefer
 `db:exec()`, `db:query()`, `db:query_one()`, and `db:transaction()`
 over manual statement preparation, binding, and stepping.
 The underlying lsqlite3 bindings are used internally; prefer the
 high-level API shown below.

     local sqlite = require("cosmic.sqlite")
     local db = sqlite.open(":memory:")
     db:exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
     db:exec("INSERT INTO users (name) VALUES (?)", "alice")
     for row in db:query("SELECT * FROM users WHERE name = ?", "alice") do
       print(row.id, row.name)
     end
     db:close()

## Types

### RawStatement

```teal
local record RawStatement
  bind_values: function(self: RawStatement, ...: any): number
  bind: function(self: RawStatement, n: number, value?: any): number
  bind_names: function(self: RawStatement, params: {string: any}): number
  bind_parameter_count: function(self: RawStatement): number
  step: function(self: RawStatement): number
  reset: function(self: RawStatement)
  finalize: function(self: RawStatement): number
  get_value: function(self: RawStatement, n: number): any
  columns: function(self: RawStatement): number
  get_name: function(self: RawStatement, n: number): string
end
```

### RawDatabase

```teal
local record RawDatabase
  close: function(self: RawDatabase): number
  exec: function(self: RawDatabase, sql: string): number
  prepare: function(self: RawDatabase, sql: string): RawStatement, number, string
  last_insert_rowid: function(self: RawDatabase): number
  changes: function(self: RawDatabase): number
  errmsg: function(self: RawDatabase): string
end
```

### RawSqlite3

```teal
local record RawSqlite3
  OK: number
  ROW: number
  DONE: number
  SCHEMA: number
  open: function(filename: string): RawDatabase, number, string
end
```

### Rows

 Callable row iterator with an out-of-band error channel. Use it in a
 generic `for row in ... do` loop, then call `:err()` afterward to detect
 a step error (SQLITE_BUSY / CORRUPT / a RETURNING constraint failure)
 that a for-loop cannot observe inline. `:err()` is nil only when
 iteration reached SQLITE_DONE cleanly.

```teal
local record Rows
  __call: function(self: Rows): {string: any}
  err: function(self: Rows): string
end
```

### Values

 Callable positional-value iterator, the `Statement:values()` counterpart
 to `Rows`. Same `:err()` contract.

```teal
local record Values
  __call: function(self: Values): any ...
  err: function(self: Values): string
end
```

### Statement

 Statement handle with automatic cleanup.

```teal
local record Statement
  bind: function(self: Statement, ...: any): boolean, string
  bind_list: function(self: Statement, values: {any}): boolean, string
  bind_named: function(self: Statement, params: {string: any}): boolean, string
  rows: function(self: Statement): Rows
  values: function(self: Statement): Values
  exec: function(self: Statement): boolean, string
  reset: function(self: Statement)
  columns: function(self: Statement): number
  column_name: function(self: Statement, n: number): string
  close: function(self: Statement)
end
```

### Database

 Database handle with automatic cleanup.

```teal
local record Database
  prepare: function(self: Database, sql: string): Statement, string
  query: function(self: Database, sql: string, ...: any): Rows, string
  query_list: function(self: Database, sql: string, values: {any}): Rows, string
  query_named: function(self: Database, sql: string, params: {string: any}): Rows, string
  query_one: function(self: Database, sql: string, ...: any): {string: any}, string
  exec: function(self: Database, sql: string, ...: any): boolean, string
  exec_list: function(self: Database, sql: string, values: {any}): boolean, string
  exec_named: function(self: Database, sql: string, params: {string: any}): boolean, string
  transaction: function(self: Database, fn: function(Database)): boolean, string
  last_insert_rowid: function(self: Database): number
  changes: function(self: Database): number
  close: function(self: Database)
end
```

### sqlite

```teal
local record sqlite
  open: function(filename: string): Database, string
  Database: Database
  Statement: Statement
end
```

## Functions

### stmt:bind

```teal
function stmt:bind(...: any): boolean, string
```

 Bind parameters by position. Handles trailing nil values correctly
 (unlike varargs with table.unpack which drops them).

### stmt:bind_list

```teal
function stmt:bind_list(values: {any}): boolean, string
```

 Bind parameters from a list (table).
 The parameter count is derived from the SQL statement itself, so
 nil values in the table are handled correctly without an explicit count.

### stmt:bind_named

```teal
function stmt:bind_named(params: {string: any}): boolean, string
```

 Bind named parameters from a key/value table.
 SQL should use :name placeholders (e.g. ":foo", ":bar").
 Table keys are names without the colon prefix.

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
function db:prepare(sql: string): Statement, string
```

### db:query

```teal
function db:query(sql: string, ...: any): Rows, string
```

### db:exec

```teal
function db:exec(sql: string, ...: any): boolean, string
```

### db:exec_list

```teal
function db:exec_list(sql: string, values: {any}): boolean, string
```

 Execute SQL with parameters from a list (table).
 The parameter count is derived from the SQL itself, so nil values
 in the table are handled correctly.

### db:exec_named

```teal
function db:exec_named(sql: string, params: {string: any}): boolean, string
```

 Execute SQL with named parameters.
 SQL should use :name placeholders. Table keys are names without the colon.

### db:query_list

```teal
function db:query_list(sql: string, values: {any}): Rows, string
```

 Query with parameters from a list (table).
 The parameter count is derived from the SQL itself, so nil values
 in the table are handled correctly.

### db:query_named

```teal
function db:query_named(sql: string, params: {string: any}): Rows, string
```

 Query with named parameters.
 SQL should use :name placeholders. Table keys are names without the colon.

### db:query_one

```teal
function db:query_one(sql: string, ...: any): {string: any}, string
```

 Return the first row matching a query, or nil if no rows match.
 Convenience method for single-row lookups.
 The underlying prepared statement is always finalized before returning,
 even when only the first row is consumed, preventing statement leaks.

### db:transaction

```teal
function db:transaction(fn: function(Database)): boolean, string
```

 Execute fn within a transaction. Calls BEGIN before fn, COMMIT after
 fn returns, and ROLLBACK if fn raises an error.
 Returns true on success, or false and an error message on failure.

### db:last_insert_rowid

```teal
function db:last_insert_rowid(): number
```

### db:changes

```teal
function db:changes(): number
```
