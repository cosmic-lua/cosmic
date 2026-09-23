--- SQLite at the Lua boundary, as the core provides it. Values keep
--- their type across it: text and bytes are separate calls, a parameter
--- is bound by an explicit call rather than guessed from a Lua value,
--- and a handle that has been closed fails the same way from every
--- method.

local record sqlite
  record Statement
    userdata

    --- Highest parameter index (including gaps introduced by ?NNN).
    parameters: function(Statement): integer

    bind_null: function(Statement, index: integer): boolean, string
    bind_integer: function(Statement, index: integer, value: integer): boolean, string
    bind_number: function(Statement, index: integer, value: number): boolean, string
    bind_text: function(Statement, index: integer, value: string): boolean, string
    bind_blob: function(Statement, index: integer, value: string): boolean, string

    --- "row" when a row is ready, "done" when the statement is finished.
    step: function(Statement): string | nil, string
    columns: function(Statement): integer
    --- One of "integer", "number", "text", "blob", "null".
    kind: function(Statement, index: integer): string
    integer: function(Statement, index: integer): integer
    number: function(Statement, index: integer): number
    bytes: function(Statement, index: integer): string
    reset: function(Statement): boolean, string
    finalize: function(Statement): boolean
  end

  record Handle
    userdata

    exec: function(Handle, sql: string): boolean, string
    prepare: function(Handle, sql: string): Statement | nil, string
    close: function(Handle): boolean, string
    changes: function(Handle): integer
    last_insert_rowid: function(Handle): integer
  end

  --- `writable` opens for reading and writing, creating the file when it
  --- is missing; without it the database is read-only. Every handle
  --- knows `sha256(X)`, `digest(A, X)` and `hmac(A, K, X)`, the digests
  --- the core provides, so a query hashes in place.
  open: function(path: string, writable?: boolean): Handle | nil, string
  version: string
end

return sqlite
