# sqlite

 Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns.
 Wraps lsqlite3 with proper error returns and resource management.

## Types

### RawStatement

```teal
local record RawStatement
  bind_values: function(self: RawStatement, ...: any): number
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
  rows: function(self: Statement): function(): {string:any}
  values: function(self: Statement): function(): any...
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
  query: function(self: Database, sql: string, ...: any): function(): {string:any}
  exec: function(self: Database, sql: string): boolean, string
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

### stmt:rows

```teal
function stmt:rows(): function(): {string:any}
```

### stmt:values

```teal
function stmt:values(): function(): any...
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
function db:query(sql: string, ...: any): function(): {string:any}
```

### db:exec

```teal
function db:exec(sql: string): boolean, string
```

### db:last_insert_rowid

```teal
function db:last_insert_rowid(): number
```

### db:changes

```teal
function db:changes(): number
```
