# sqlite

 Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns.
 Wraps lsqlite3 with proper error returns and resource management.

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
  open: function(filename: string): RawDatabase, number, string
end
```

### Statement

 Statement handle with automatic cleanup.

```teal
local record Statement
  bind: function(self: Statement, ...: any): boolean, string
  bind_list: function(self: Statement, values: {any}): boolean, string
  bind_named: function(self: Statement, params: {string: any}): boolean, string
  rows: function(self: Statement): function(): {string: any}
  values: function(self: Statement): function(): any ...
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
  query: function(self: Database, sql: string, ...: any): function(): {string: any}
  query_list: function(self: Database, sql: string, values: {any}): function(): {string: any}
  query_named: function(self: Database, sql: string, params: {string: any}): function(): {string: any}
  query_one: function(self: Database, sql: string, ...: any): {string: any}
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
function stmt:rows(): function(): {string: any}
```

### stmt:values

```teal
function stmt:values(): function(): any ...
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
function db:query(sql: string, ...: any): function(): {string: any}
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
function db:query_list(sql: string, values: {any}): function(): {string: any}
```

 Query with parameters from a list (table).
 The parameter count is derived from the SQL itself, so nil values
 in the table are handled correctly.

### db:query_named

```teal
function db:query_named(sql: string, params: {string: any}): function(): {string: any}
```

 Query with named parameters.
 SQL should use :name placeholders. Table keys are names without the colon.

### db:query_one

```teal
function db:query_one(sql: string, ...: any): {string: any}
```

 Return the first row matching a query, or nil if no rows match.
 Convenience method for single-row lookups.

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
