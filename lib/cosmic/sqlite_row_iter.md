# sqlite_row_iter

 Internal helper for cosmic.sqlite: the row iterator for db:query's hot
 path. Collapses what used to be a full Statement object (~10 method
 closures) + Statement:rows() + a close-on-drain wrapper into a single
 iterator that steps the raw statement directly, resolves column names
 once on the first row, and releases the statement when iteration drains.
 Lives in its own file so cosmic/sqlite.tl stays under the 500-line cap.

## Types

### RawStatement

```teal
local record RawStatement
  bind: function(self: RawStatement, n: number, value?: any): number
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
  errmsg: function(self: RawDatabase): string
end
```

### Rows

```teal
local record Rows
  __call: function(self: Rows): {string: any}
  err: function(self: Rows): string
end
```
