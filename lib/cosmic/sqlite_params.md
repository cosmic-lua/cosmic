# sqlite_params

 Internal helper for cosmic.sqlite: the list/named parameter convenience
 methods (exec_list, exec_named, query_list, query_named) attached onto a
 Database. They all follow the same prepare/bind/consume shape, so they
 live together here. Lives in its own file so cosmic/sqlite.tl stays
 under the 500-line cap.

## Types

### Rows

```teal
local record Rows
  __call: function(self: Rows): {string: any}
  err: function(self: Rows): string
end
```

### Stmt

```teal
local record Stmt
  bind_list: function(self: Stmt, values: {any}): boolean, string
  bind_named: function(self: Stmt, params: {string: any}): boolean, string
  exec: function(self: Stmt): boolean, string
  rows: function(self: Stmt): Rows
  close: function(self: Stmt)
end
```

### Db

```teal
local record Db
  prepare: function(self: Db, sql: string): Stmt | nil, string
  exec_list: function(self: Db, sql: string, values: {any}): boolean, string
  exec_named: function(self: Db, sql: string, params: {string: any}): boolean, string
  query_list: function(self: Db, sql: string, values: {any}): Rows | nil, string
  query_named: function(self: Db, sql: string, params: {string: any}): Rows | nil, string
end
```

## Functions

### db:exec_list

```teal
function db:exec_list(sql: string, values: {any}): boolean, string
```

 Execute SQL with parameters from a list (table). The count is derived
 from the SQL itself, so nil values in the table are handled correctly.

### db:exec_named

```teal
function db:exec_named(sql: string, params: {string: any}): boolean, string
```

 Execute SQL with named parameters.
 SQL should use :name placeholders. Table keys are names without the colon.

### db:query_list

```teal
function db:query_list(sql: string, values: {any}): Rows | nil, string
```

 Query with parameters from a list (table).
 The parameter count is derived from the SQL itself, so nil values
 in the table are handled correctly.

### db:query_named

```teal
function db:query_named(sql: string, params: {string: any}): Rows | nil, string
```

 Query with named parameters.
 SQL should use :name placeholders. Table keys are names without the colon.
