--- SQLite at the Lua boundary, as the core provides it. Values keep
--- their type across it: text and bytes are separate calls, a parameter
--- is bound by an explicit call rather than guessed from a Lua value,
--- and a handle that has been closed fails the same way from every
--- method.
--- @kind binding

local record sqlite
  interface Outcome
    code: integer
    extended_code: integer
    reason: string
    cancelled: boolean
    --- True where `handle:time_limit(ns)` stopped the call; absent else.
    timed_out?: boolean
  end
  record ExecResult is Outcome
    code: integer
    extended_code: integer
    reason: string
    cancelled?: boolean -- declared: interface_disagrees
    timed_out?: boolean
  end
  record WalResult is Outcome
    code: integer
    extended_code: integer
    reason: string
    cancelled: boolean
    timed_out?: boolean
    mode: string
    temporary: boolean
  end
  record OpenResult is Outcome
    handle: Handle
    code: integer
    extended_code: integer
    reason: string
    cancelled: boolean
    timed_out?: boolean
  end
  record PrepareResult is Outcome
    statement: Statement
    code: integer
    extended_code: integer
    reason: string
    cancelled: boolean
    timed_out?: boolean
  end
  record Value
    --- Bound as a 64-bit SQLite integer.
    integer?: integer
    --- Bound as a floating-point number.
    number?: number
    --- Bound as UTF-8 text, including embedded NUL.
    text?: string
    --- Bound as bytes, distinct from text.
    blob?: string
    --- Bound as an array of 64-bit integers, for `carray(?N)` alone.
    integers?: {integer}
    --- Bound as an array of floating-point numbers, for `carray(?N)` alone.
    numbers?: {number}
    --- Bound as an array of texts, each without a NUL, for `carray(?N)` alone.
    texts?: {string}
    --- Bound as an array of blobs, for `carray(?N)` alone.
    blobs?: {string}
  end
  --- One parameter as it is bound: an integer, a number, a string (as
  --- text), a boolean (as 1 or 0), or a Value that names its type.
  type Param = number | string | boolean | Value
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
    step: function(Statement): string?, string
    --- "row" or "done" without a result allocation; a captured failure otherwise.
    step_result: function(Statement): string | ExecResult
    --- Binds a dense list of explicit Values. Invalid parameter shapes raise.
    bind_values_result: function(Statement, values: {Value}): ExecResult
    --- Binds `values[1]` to `values[n]` to the statement's n parameters in
    --- one pass, each by its Lua type. Returns nothing where all are bound;
    --- otherwise the position, why, and SQLite's code, or false for a value
    --- of no shape a parameter takes (the caller raises). Only running
    --- out of memory raises, which leaves the statement to the collector.
    bind_all: function(Statement, values: {Param}): integer?, string?, (integer | boolean)?
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
    --- Rewinds the statement to run again and clears every binding, so
    --- each parameter binds again before the next step; an unbound
    --- parameter is NULL. Returns true and an empty reason, or false and
    --- the previous step's failure, in which case the statement is
    --- rewound all the same. See [`Statement.rewind`] to keep the bindings.
    reset: function(Statement): boolean, string
    --- As [`Statement.reset`], but returns SQLite's codes as
    --- [`Statement.step_result`] does. A statement stopped before its end
    --- in autocommit commits at its reset, so a failure there is its own.
    reset_result: function(Statement): ExecResult
    --- Rewinds the statement to run again and keeps every binding, as
    --- SQLite's own reset does: bind the columns that stay fixed once,
    --- then per row rebind the one that changes and rewind. It returns
    --- and fails as [`Statement.reset`] does.
    ---
    --- ```
    --- local insert = assert(connection:prepare("INSERT INTO t (owner, n) VALUES (?1, ?2)"))
    --- assert(insert:bind_text(1, "me"))
    --- for n = 1, 3 do
    ---   assert(insert:bind_integer(2, n))
    ---   assert(insert:step() == "done")
    ---   assert(insert:rewind())
    --- end
    --- insert:finalize()
    --- ```
    rewind: function(Statement): boolean, string
    --- Releases the statement. Finalizing one already finalized does
    --- nothing.
    finalize: function(Statement)
    --- Done with the statement: one [`Handle.prepare_cached_result`] made
    --- goes back to its handle, rewound and its bindings cleared, for the
    --- same SQL to take again; any other is finalized. Releasing one
    --- already released or finalized does nothing.
    release: function(Statement)
    --- The row the statement stands on as one table of two slots a
    --- column, its kind then its value (`false` for NULL), with
    --- `metatable`; with `as_text`, every column `"text"` and its bytes,
    --- NULL as `""`. Empty where the statement stands on no row.
    row: function<T>(Statement, metatable: metatable<T>, as_text?: boolean): T
  end

  --- One database connection. Every call on a closed handle raises.
  record Handle
    userdata

    --- Runs every statement in `sql`, discarding any rows, with no
    --- parameter binding: schema DDL, PRAGMAs, or several
    --- `;`-separated statements in one call -- the one thing a typed
    --- handle's `run`, `rows` and `text_rows` cannot do, since each of
    --- those prepares exactly one statement. Reach for `run` once a value
    --- needs binding.
    exec: function(Handle, sql: string): boolean, string
    --- Executes once and snapshots the result before another operation
    --- changes it. Embedded NUL raises; exec returns false and a reason.
    exec_result: function(Handle, sql: string): ExecResult
    --- Waits up to timeout_ns at locks, rounded up to milliseconds,
    --- checking the innermost guard's unread signal without taking it.
    --- Each exec, prepare, step, reset, rewind or finalize shares one budget
    --- across its locking events, starting at the first contention.
    --- Zero never sleeps. Negative/noninteger durations and borrowed
    --- or closed handles raise. Without a guard, only the time limits it.
    --- PRAGMA busy_timeout reads zero for this custom handler; writing
    --- that pragma replaces it. Call this method again to reinstall it.
    --- SQLite can refuse a lock without calling any busy handler.
    busy_timeout: function(Handle, timeout_ns: integer)
    --- Stops each later exec or step that runs past timeout_ns, rounded up
    --- to milliseconds from the call's start, as SQLite's progress handler
    --- looks every thousand steps of its virtual machine (a statement of
    --- fewer is never stopped): the call fails with SQLITE_INTERRUPT and
    --- "the call ran past its time limit", its outcome `timed_out`. An
    --- interrupted write rolls back the open transaction; a read leaves
    --- it. A guard's unread signal stops a call so too, its outcome
    --- `cancelled`. Only exec and step say which stopped them; a reset
    --- after says "interrupted". nil takes the limit away, though a
    --- guard's signal still stops a call. A negative or noninteger
    --- duration and a borrowed or closed handle raise.
    time_limit: function(Handle, timeout_ns?: integer)
    --- Holds the handle to queries for good: see [`cosmic.sqlite`]'s
    --- [`Handle.reads_only`]. A borrowed handle raises.
    reads_only: function(Handle): boolean, string
    --- Whether a transaction is open on the connection: a `BEGIN`, or a
    --- `SAVEPOINT` outside one, not yet committed or rolled back.
    in_transaction: function(Handle): boolean
    --- Whether the connection's main database is read-only.
    read_only: function(Handle): boolean
    --- Switches the main database to write-ahead mode, trying a busy
    --- refusal again until the handle's wait has passed, and returns the
    --- mode it is in after as `mode`, and whether the database is a
    --- temporary or memory one as `temporary`. A borrowed handle raises.
    wal_result: function(Handle): WalResult
    --- Compiles `sql`, which must hold exactly one statement.
    prepare: function(Handle, sql: string): Statement?, string
    --- Captures a preparation's outcome before cleanup or another operation.
    --- Empty, multiple, overlong or NUL-containing SQL raises.
    prepare_result: function(Handle, sql: string): PrepareResult
    --- As [`prepare_result`], but the statement a [`Statement.release`] of
    --- one prepared from the same SQL kept, where the handle keeps one: a
    --- handle that owns its connection keeps up to 16, and closing it
    --- finalizes them first. A borrowed handle keeps none.
    prepare_cached_result: function(Handle, sql: string): PrepareResult
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
    --- `"worker_threads"`), and returns the value it had. A negative
    --- `value` changes nothing, so it reads the limit. A value above the
    --- library's own ceiling raises, naming the ceiling, as does an
    --- unknown name. `"attached"` starts at 10 and may be raised to 125.
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
  --- `writable` raises. Writable opens create a missing file unless
  --- `create` is explicitly false; read-only opens never create. Every
  --- handle checks each cell's size as it reads it, and is in SQLite's
  --- defensive mode unless `defensive` is explicitly false.
  open: function(path: string, writable?: boolean, immutable?: boolean, create?: boolean, defensive?: boolean): Handle?, string
  --- A captured open outcome. Invalid path/options raise.
  open_result: function(path: string, writable?: boolean, immutable?: boolean, create?: boolean, defensive?: boolean): OpenResult
  --- Disowns every connection this process has open through this module ([`cosmic.sqlite`]'s `disown`).
  disown: function()
  --- The SQLite library's version, such as "3.54.1".
  version: string
  --- `x` as SQLite writes a REAL as text: what `CAST(x AS TEXT)` and a
  --- column's text answer for it.
  number_text: function(x: number): string
  --- The one read-only empty Value, which binds NULL.
  NULL: Value
end

return sqlite
