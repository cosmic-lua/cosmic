# sqlite_stmt_cache

 Internal helper for cosmic.sqlite: caches prepared statements by SQL
 text so db:exec can reuse a statement across repeated calls with the
 same SQL (e.g. inside a loop in a transaction) instead of preparing
 and finalizing a fresh one every time.

## Types

### RawStatement

```teal
local record RawStatement
  bind: function(self: RawStatement, n: number, value?: any): number
  step: function(self: RawStatement): number
  reset: function(self: RawStatement)
  finalize: function(self: RawStatement): number
end
```

### RawDatabase

```teal
local record RawDatabase
  prepare: function(self: RawDatabase, sql: string): RawStatement, number, string
  errmsg: function(self: RawDatabase): string
end
```

### StmtCache

```teal
local record StmtCache
  exec: function(self: StmtCache, sql: string, args: {integer: any}, n: integer): boolean, string
  checkout: function(self: StmtCache, sql: string): RawStatement | nil, OnClose, string
  close_all: function(self: StmtCache)
end
```

## Functions

### self:checkout

```teal
function self:checkout(sql: string): RawStatement | nil, OnClose, string
```

 Check out a statement for db:query, preparing and caching one if this
 SQL text hasn't been queried yet. Returns (statement, on_close):
 on_close is non-nil when the statement is the shared cached one —
 the caller must call it (instead of finalizing) when its Rows
 iterator finishes, to return the slot. When the cached slot for
 this SQL is already checked out by an unfinished query
 (nested/interleaved queries for the same SQL text), a fresh
 throwaway statement is prepared instead and on_close is nil — the
 caller finalizes it itself, same as an uncached prepare.

### self:exec

```teal
function self:exec(sql: string, args: {integer: any}, n: integer): boolean, string
```

 Execute a parameterized statement once, reusing (or preparing and
 caching) the statement for `sql`. On SQLITE_SCHEMA, drops the stale
 statement and retries once (sqlite3 already retries internally
 before surfacing SCHEMA, so a second failure is a real error).
