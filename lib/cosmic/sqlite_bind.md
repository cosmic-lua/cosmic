# sqlite_bind

 Internal helper for cosmic.sqlite: the BLOB value marker and the shared
 positional bind step. Every bind loop (Statement:bind/bind_list, the
 db:exec statement cache, the db:query hot path) funnels through
 `bind_at`, so a value wrapped with `blob()` is bound with SQLite blob
 affinity everywhere instead of defaulting to TEXT.
 Lives in its own file so cosmic/sqlite.tl stays under the 500-line cap.

## Types

### Blob

 Marker wrapper produced by `cosmic.sqlite.blob()`. Bind loops detect it
 by metatable identity and bind `data` via `bind_blob` instead of `bind`.

```teal
local record Blob
  data: string
end
```

### RawStatement

```teal
local record RawStatement
  bind: function(self: RawStatement, n: number, value?: any): number
  bind_blob: function(self: RawStatement, n: number, blob: string): number
end
```

### M

```teal
local record M
  blob: function(data: string): Blob
  is_blob: function(v: any): boolean
  bind_at: function(raw_stmt_any: any, i: integer, v: any): number
end
```
