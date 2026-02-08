# lsqlite3

Type declarations for the `lsqlite3` module.

## Types

### Statement

 Statement object returned by Database:prepare()

```teal
local record Statement
  --  Binds a sequence of values to sequential parameters (1, 2, 3, ...)
  --  Returns sqlite3.OK on success or error code on failure
  bind_values: function(Statement, any...): number
  --  Binds value to parameter n (1-indexed)
  --  String/number become text/double; nil clears binding
  --  Returns sqlite3.OK on success or error code on failure
  bind: function(Statement, n: number, value?: any): number
  --  Executes next iteration of prepared statement
  --  Returns sqlite3.ROW (data ready), sqlite3.DONE (finished), or error code
  step: function(Statement): number
  --  Resets statement to initial state for re-execution
  --  Retains parameter bindings from previous bind calls
  reset: function(Statement)
  --  Deallocates prepared statement resources
  --  Returns sqlite3.OK on success or error code if execution failed
  finalize: function(Statement): number
  --  Returns value of column n (0-indexed) from current row
  get_value: function(Statement, n: number): any
  --  Returns count of columns in result set (or 0 for non-query statements)
  columns: function(Statement): number
  --  Returns column name for column n (0-indexed)
  get_name: function(Statement, n: number): string
  --  Returns the number of SQL parameters in the prepared statement
  bind_parameter_count: function(Statement): number
  --  Returns the name of the n-th parameter (1-indexed), or nil for positional (?) params
  bind_parameter_name: function(Statement, n: number): string
  --  Binds named parameters from a key/value table.
  --  Keys are parameter names without the prefix (e.g. "foo" for ":foo").
  --  Returns sqlite3.OK on success or error code on failure.
  bind_names: function(Statement, params: {string:any}): number
end
```

### Database

 Database handle returned by lsqlite3.open() and lsqlite3.open_memory()

```teal
local record Database
  --  Closes database connection
  --  Returns sqlite3.OK on success or error code on failure
  close: function(Database): number
  --  Compiles and executes one or more SQL statements
  --  Optional callback invoked per result row with (udata, colcount, values, names)
  --  Returns sqlite3.OK on success or error code on failure
  exec: function(Database, sql: string, func?: function, udata?: any): number
  --  Compiles SQL statement into prepared statement for reuse
  --  Returns Statement on success, or (nil, errcode, errmsg) on failure
  prepare: function(Database, sql: string): Statement | nil, number | nil, string | nil
  --  Creates iterator yielding rows as tables with named fields (column_name: value)
  --  Each iteration returns one row as associative table
  nrows: function(Database, sql: string): function(): {string:any}
  --  Creates iterator yielding rows as indexed tables (1: value1, 2: value2, ...)
  --  Each iteration returns one row as array with numeric indices
  rows: function(Database, sql: string): function(): {any}
  --  Creates iterator yielding column values directly (value1, value2, ...)
  --  Each iteration returns unpacked values for one row
  urows: function(Database, sql: string): function(): any...
  --  Returns rowid of most recent INSERT operation
  --  Returns 0 if no inserts have occurred
  last_insert_rowid: function(Database): number
  --  Returns count of rows modified by most recent INSERT, UPDATE, or DELETE
  --  Excludes trigger-caused changes
  changes: function(Database): number
  --  Returns cumulative count of all rows modified since database opened
  --  Includes changes in triggers
  total_changes: function(Database): number
  --  Retrieves numerical error code from most recent failed operation
  errcode: function(Database): number
  --  Retrieves human-readable error message for most recent failed call
  errmsg: function(Database): string
end
```

### lsqlite3 Constants

Constants defined in the lsqlite3 module.

```teal
local record lsqlite3 Constants
  OK: number
  ERROR: number
  INTERNAL: number
  PERM: number
  ABORT: number
  BUSY: number
  LOCKED: number
  NOMEM: number
  READONLY: number
  INTERRUPT: number
  IOERR: number
  CORRUPT: number
  NOTFOUND: number
  FULL: number
  CANTOPEN: number
  PROTOCOL: number
  EMPTY: number
  SCHEMA: number
  TOOBIG: number
  CONSTRAINT: number
  MISMATCH: number
  MISUSE: number
  NOLFS: number
  FORMAT: number
  RANGE: number
  NOTADB: number
  ROW: number
  DONE: number
  CREATE_INDEX: number
  CREATE_TABLE: number
  CREATE_TEMP_INDEX: number
  CREATE_TEMP_TABLE: number
  CREATE_TEMP_TRIGGER: number
  CREATE_TEMP_VIEW: number
  CREATE_TRIGGER: number
  CREATE_VIEW: number
  DELETE: number
  DROP_INDEX: number
  DROP_TABLE: number
  DROP_TEMP_INDEX: number
  DROP_TEMP_TABLE: number
  DROP_TEMP_TRIGGER: number
  DROP_TEMP_VIEW: number
  DROP_TRIGGER: number
  DROP_VIEW: number
  INSERT: number
  PRAGMA: number
  READ: number
  SELECT: number
  TRANSACTION: number
  UPDATE: number
  ATTACH: number
  DETACH: number
  ALTER_TABLE: number
  REINDEX: number
  ANALYZE: number
  CREATE_VTABLE: number
  DROP_VTABLE: number
  FUNCTION: number
  SAVEPOINT: number
  OPEN_CREATE: number
  OPEN_PRIVATECACHE: number
  OPEN_FULLMUTEX: number
  OPEN_NOMUTEX: number
  OPEN_MEMORY: number
  OPEN_URI: number
  OPEN_READWRITE: number
  OPEN_READONLY: number
  OPEN_SHAREDCACHE: number
  TEXT: number
  BLOB: number
  NULL: number
  FLOAT: number
end
```

## Functions

### open

```teal
function open(filename: string, flags?: number): Database
```

 Opens (or creates if it does not exist) an SQLite database with name filename
 and returns its handle as userdata (the returned object should be used for all
 further method calls in connection with this specific database, see Database
 methods). Example:
 myDB = lsqlite3.open('MyDatabase.sqlite3')  -- open
 -- do some database calls...
 myDB:close()  -- close
 In case of an error, the function returns `nil`, an error code and an error message.
 Since `0.9.4`, there is a second optional `flags` argument to `lsqlite3.open`.
 See https://www.sqlite.org/c3ref/open.html for an explanation of these flags and options.
 local db = lsqlite3.open('foo.db', lsqlite3.OPEN_READWRITE + lsqlite3.OPEN_CREATE + lsqlite3.OPEN_SHAREDCACHE)

**Parameters:**

- `filename` (string)
- `flags` (number)

**Returns:**

- Database

### open_memory

```teal
function open_memory(): Database
```

 Opens an SQLite database in memory and returns its handle as userdata. In case
 of an error, the function returns `nil`, an error code and an error message.
 (In-memory databases are volatile as they are never stored on disk.)

**Returns:**

- Database

### lversion

```teal
function lversion(): string
```

**Returns:**

- string

### version

```teal
function version(): string
```

**Returns:**

- string
