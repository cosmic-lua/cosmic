--- SQLite at the Lua boundary, as the core provides it. Values keep
--- their type across it: text and bytes are separate calls, a parameter
--- is bound by an explicit call rather than guessed from a Lua value,
--- and a handle that has been closed fails the same way from every
--- method.

local record sqlite
  record ExecResult
    code: integer
    extended_code: integer
    reason: string
  end
  --- One prepared statement. It keeps its handle alive while it is
  --- open. Every call on a finalized statement raises.
  record Statement
    userdata

    --- Highest parameter index (including gaps introduced by ?NNN).
    parameters: function(Statement): integer

    --- Binds NULL to the parameter at `index`, counting from 1.
    bind_null: function(Statement, index: integer): boolean, string
    --- Binds a 64-bit integer to the parameter at `index`.
    bind_integer: function(Statement, index: integer, value: integer): boolean, string
    --- Binds a floating-point number to the parameter at `index`.
    bind_number: function(Statement, index: integer, value: number): boolean, string
    --- Binds `value` as UTF-8 text to the parameter at `index`.
    bind_text: function(Statement, index: integer, value: string): boolean, string
    --- Binds `value`'s bytes as a blob to the parameter at `index`.
    bind_blob: function(Statement, index: integer, value: string): boolean, string

    --- "row" when a row is ready, "done" when the statement is finished.
    step: function(Statement): string | nil, string
    --- How many columns a row of this statement has.
    columns: function(Statement): integer
    --- The name of the column at `index`, from zero: its `AS` alias,
    --- or what SQLite calls it without one. Known before any row.
    name: function(Statement, index: integer): string
    --- One of "integer", "number", "text", "blob", "null".
    kind: function(Statement, index: integer): string
    --- The column at `index`, counting from 0, of the current row, as
    --- an integer. A column the current row does not have raises, as
    --- in every column read.
    integer: function(Statement, index: integer): integer
    --- The column at `index` of the current row, as a number.
    number: function(Statement, index: integer): number
    --- The column at `index` of the current row, as its bytes: text
    --- and blobs alike, `""` for an empty value.
    bytes: function(Statement, index: integer): string
    --- Rewinds the statement to run again and clears every binding.
    reset: function(Statement): boolean, string
    --- Releases the statement. Finalizing one already finalized does
    --- nothing.
    finalize: function(Statement)
  end

  --- One database connection. Every call on a closed handle raises.
  record Handle
    userdata

    --- Runs every statement in `sql`, discarding any rows, with no
    --- parameter binding: schema DDL, PRAGMAs, or several
    --- `;`-separated statements in one call -- the one thing
    --- [`Sqlite.run`], `rows` and `text_rows` cannot do, since each of
    --- those prepares exactly one statement. Reach for [`Sqlite.run`]
    --- once a value needs binding.
    exec: function(Handle, sql: string): boolean, string
    --- Executes once and snapshots the result before another operation
    --- changes it. Embedded NUL raises; exec returns false and a reason.
    exec_result: function(Handle, sql: string): ExecResult
    --- Compiles `sql`, which must hold exactly one statement.
    prepare: function(Handle, sql: string): Statement | nil, string
    --- Closes the connection; closing one already closed does nothing.
    --- A borrowed handle, such as the store's, only lets go of it.
    close: function(Handle): boolean, string
    --- How many rows the most recent INSERT, UPDATE or DELETE on this
    --- connection changed -- not the whole database's, and not another
    --- connection's.
    changes: function(Handle): integer
    --- The rowid SQLite assigned the most recent successful INSERT on
    --- this connection: 0 before any has run on it, and a table
    --- declared `WITHOUT ROWID` never changes it.
    last_insert_rowid: function(Handle): integer
    --- Sets one of the connection's limits, named as SQLite's
    --- `SQLITE_LIMIT_*` without the prefix, lower-cased (`"attached"`,
    --- `"sql_length"`, `"length"`, `"column"`, `"expr_depth"`,
    --- `"compound_select"`, `"vdbe_op"`, `"function_arg"`,
    --- `"like_pattern_length"`, `"variable_number"`, `"trigger_depth"`,
    --- `"worker_threads"`), and answers the value it had. A negative
    --- `value` changes nothing, so it reads the limit; a value above the
    --- library's own ceiling is lowered to it. An unknown name raises.
    limit: function(Handle, name: string, value: integer): integer
  end

  --- `writable` opens for reading and writing, creating the file when it
  --- is missing; without it the database is read-only. Every handle
  --- knows `sha256(X)`, `digest(A, X)` and `hmac(A, K, X)`, the digests
  --- the core provides, so a query hashes in place. `immutable` opens
  --- read-only a file nothing will change while it is open (SQLite's
  --- `immutable=1`): no lock is taken and no `-wal`, `-shm` or journal
  --- file is made or read, so a WAL-mode database with its `-wal` gone
  --- opens without leaving either beside it, and a statement holds
  --- nothing another process's write waits on. A `-wal` is never read,
  --- so a database with commits still in its `-wal` shows without them:
  --- open it the ordinary read-only way instead. Giving it with
  --- `writable` raises.
  open: function(path: string, writable?: boolean, immutable?: boolean): Handle | nil, string
  --- The SQLite library's version, such as "3.53.4".
  version: string
end

return sqlite
