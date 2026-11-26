--- SQLite, typed: cosmic's embedded SQL database, a `db` in one file or in
--- memory, with no server and nothing to install.
---
--- Values keep their type: text and bytes are different, and a parameter
--- is bound by naming what it is. A handle's methods give the shapes a
--- caller wants: a query that yields rows, all at once (`db:rows`) or
--- one at a time (`db:query`), a statement run once (`db:run`), and a
--- transaction that rolls back when the work inside it fails
--- (`db:transact`); each returns nil or false and a [`Failure`] when
--- SQLite refuses.
---
--- Parameters are a list of values, one per `?N`, in order; a result
--- row is read a column at a time by the type the caller expects, from
--- 1:
---
---     local db = assert(Sqlite.open("notes.db", { writable = true }))
---     assert(db:exec("CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, body TEXT)"))
---     assert(db:run("INSERT INTO t (body) VALUES (?1)", { "hi" }))
---     local rows = assert(db:rows("SELECT id, body FROM t WHERE id = ?1",
---       { db:last_insert_rowid() }))
---     print(rows[1]:integer(1), rows[1]:text(2)) -- 1  hi
---
--- An integer, a float, a string (as text) and a boolean (as 1 or 0) bind
--- as themselves; `Sqlite.blob(b)` binds bytes as a blob and [`Sqlite.NULL`]
--- binds NULL ([`Sqlite.Param`]). A [`Sqlite.Row`] is not a list:
--- `row:text(2)`, `row:integer(2)`, `row:number(2)` and `row:blob(2)` return
--- column 2 when it holds that type, and raise when it does not;
--- [`Handle.map`] turns each row into a record of such reads.
---
--- To query a database file from the shell, `cosmic sql --db notes.db
--- '<statement>'` runs one read-only statement; no `sqlite3` binary or
--- other language is needed.
---
--- To copy tables between database files, open the target writable and
--- `ATTACH` the other file; [the SQL guide](doc/guides/sql.md) has the
--- sections "copying tables between files" and "prepared statements".
--- `cosmic sql` cannot attach.
---
--- SQLite's JSON functions read JSON5 always, and in cosmic's copy `#`
--- line comments too, as `cosmic.json` does given `hash_comments`: a
--- text in YAML's flow style reads the same through either.
---
--- Every handle has the SQL functions, virtual tables and
--- collations [the SQL guide](doc/guides/sql.md) lists, and only those:
--- SQLite's own, its math and percentile functions, cosmic's, and the
--- extensions from SQLite's `ext/misc/` the core is built with
--- (`generate_series`, `REGEXP`, `decimal`, `uuid`, `sha3`, `base64`,
--- `compress`, ...).

-- The raw module behind this one lives under the reserved
-- `cosmic.internal.` namespace, which only cosmic's own tree may require
-- (see cosmic/store.tl for why it is off the public surface).
local type raw_sqlite = require("cosmic.internal.sqlite")

local sqlite = require("cosmic.internal.sqlite")
local Failure = require("cosmic.failure")
local sys = require("cosmic.sys")
local Waits = require("cosmic.internal.waits")

--- The SQLite storage class of a result cell, as [`Sqlite.Row.kind`] names
--- it.
local enum Kind
  "null"
  "integer"
  "number"
  "text"
  "blob"
end

--- One result row. Every accessor is positional, so a `SELECT` whose
--- columns are reordered still type-checks and reads the wrong column:
--- [`Handle.map`] keeps the column order beside the reads, in one
--- function, and is the way to read rows rather than numbering columns
--- at each call.
---
--- A row is read a column at a time. A column is its position
--- from 1; the accessor names the type the caller expects, and a
--- column of any other type raises, as does a position the row has no
--- column at, so a query that does not yield what the reader assumed
--- fails where it is read, not later. A row is no list: it has no
--- numeric keys, and `#row` is not its length (use `count`). Code the
--- checker does not see (a cast, an `any`, a Lua chunk) that indexes a row
--- reads the row's internal slots, kinds mixed with values, and nothing
--- refuses it: read a row only through its accessors.
---
---     local db = assert(Sqlite.memory())
---     local rows = assert(db:rows("SELECT 7, 'seven', NULL, x'ff'"))
---     local row = rows[1]
---     print(row:count(), row:integer(1), row:text(2), row:is_null(3), #row:blob(4))
---
--- `rows` returns, and [`Handle.query`] reads, rows that keep each
--- column's SQLite type; [`Handle.text_rows`] returns rows whose every
--- column is text.
local interface Row
  --- The number of columns.
  count: function(Row): integer
  --- The type of the column: `"null"` for SQL NULL. A row from
  --- [`Handle.text_rows`] has only `"text"` columns.
  kind: function(Row, integer): Kind
  --- Whether the column is SQL NULL. Always false for a row from
  --- [`Handle.text_rows`], which holds no NULL.
  is_null: function(Row, integer): boolean
  --- The column of an INTEGER cell. A number, text or NULL cell raises.
  integer: function(Row, integer): integer
  --- The column of an INTEGER or REAL cell, an integer as the nearest
  --- float (one beyond 2^53 rounds). A REAL cell is returned as stored,
  --- `-0.0` included. Text, a blob or NULL raises.
  number: function(Row, integer): number
  --- The column of a TEXT cell, or of any column of a row from
  --- [`Handle.text_rows`]. An integer, number, blob or NULL cell of a typed
  --- row raises.
  text: function(Row, integer): string
  --- The bytes of a BLOB cell. Any other cell raises, and so does a
  --- column of a row from [`Handle.text_rows`].
  blob: function(Row, integer): string
  --- The bytes of a TEXT or BLOB cell, for a column that may hold
  --- either. An integer, number or NULL cell raises.
  bytes: function(Row, integer): string
  --- The cell as SQLite casts it to text (`CAST(x AS TEXT)`): an integer
  --- or a number as SQLite writes it, the bytes of a text or a blob, and
  --- nil for NULL. It is how a cell of any type is shown.
  as_text: function(Row, integer): string?
  --- Every column as `text` returns it, in order, as a new list: for a
  --- row from [`Handle.text_rows`], its columns. A column of another type
  --- raises.
  texts: function(Row): {string}
  --- Every column as `as_text` shows it, in order, as a new list, with
  --- "" for NULL: how a row of any types is shown whole, as a test or a
  --- listing prints it. A program that reads a column reads it by its
  --- type instead.
  as_texts: function(Row): {string}
  --- The parameter that binds this column back as it is, of the type
  --- `kind` names: `{ integer = n }`, `{ number = x }`, `{ text = s }`,
  --- `{ blob = b }`, and `{}` for NULL. It is how a row is copied to
  --- another table.
  value: function(Row, integer): raw_sqlite.Value
end

-- A row is one table with a metatable, so reading a result allocates
-- the row and nothing per cell. It holds each cell as two slots, the
-- cell's kind then its value (`false` for NULL, which a table cannot
-- hold as nil). A text row is one whose every cell is text. Only the
-- accessors below look inside. A stored row has the accessors of
-- [`Sqlite.Row`] but is not declared to implement it: a record that has an
-- array part takes no interface, so the rows are cast where they are made.
-- TODO: once the grammar lets a record carry an array part and an interface, or a stored row is a class, delete
-- the cast in [`cells_of`] (and its entry in build/contract_rules.tl's casts) and list
-- [`Sqlite.Row`] on [`Stored`].
local record Stored is {any}
  count: function(Stored): integer
  kind: function(Stored, integer): Kind
  is_null: function(Stored, integer): boolean
  integer: function(Stored, integer): integer
  number: function(Stored, integer): number
  text: function(Stored, integer): string
  blob: function(Stored, integer): string
  bytes: function(Stored, integer): string
  as_text: function(Stored, integer): string?
  texts: function(Stored): {string}
  as_texts: function(Stored): {string}
  value: function(Stored, integer): raw_sqlite.Value
end

local stored_mt: metatable<Stored> = { __index = Stored } -- checked: literal_missing

--- What a cell of kind `kind` is called in a failure.
local function described(kind: Kind): string
  if kind == "null" then return "NULL" end
  if kind == "integer" then return "an integer" end
  if kind == "number" then return "a number" end
  if kind == "blob" then return "a blob" end
  return "text"
end

--- The kind a row stored for a cell.
local function kind_of(stored: any): Kind
  if stored == "integer" then return "integer" end
  if stored == "number" then return "number" end
  if stored == "text" then return "text" end
  if stored == "blob" then return "blob" end
  return "null"
end

--- The kind and value of column `index` of `row`, which `name` reads.
--- Raises, blaming the caller of the accessor that called this, unless
--- `index` is a position the row has a column at.
local function cell_at(row: Stored, index: integer, name: string): Kind, any
  local count = #row // 2
  if index < 1 or index > count then
    error("sqlite: row:" .. name .. "(" .. tostring(index) .. "): the row has " .. tostring(count) ..
        (if count == 1 then " column" else " columns" end), 3)
  end
  local at = 2 * index - 1
  return kind_of(row[at]), row[at + 1]
end

--- The failure of reading column `index` as `wants` when it holds a
--- cell of kind `kind`, blaming the caller of the accessor that raises
--- it.
local function mismatch(name: string, index: integer, kind: Kind, wants: string): string
  return "sqlite: row:" .. name .. "(" .. tostring(index) .. "): column " .. tostring(index) .. " is " ..
    described(kind) .. ", not " .. wants
end

function Stored.count(self: Stored): integer
  return #self // 2
end

function Stored.kind(self: Stored, index: integer): Kind
  local kind, _ = cell_at(self, index, "kind")
  return kind
end

function Stored.is_null(self: Stored, index: integer): boolean
  local kind, _ = cell_at(self, index, "is_null")
  return kind == "null"
end

function Stored.integer(self: Stored, index: integer): integer
  local kind, held = cell_at(self, index, "integer")
  if held is integer then return held end
  error(mismatch("integer", index, kind, "an integer"), 2)
end

function Stored.number(self: Stored, index: integer): number
  local kind, held = cell_at(self, index, "number")
  if held is integer then return held + 0.0 end
  if held is number then return held end
  error(mismatch("number", index, kind, "a number or an integer"), 2)
end

function Stored.text(self: Stored, index: integer): string
  local kind, held = cell_at(self, index, "text")
  if kind == "text" and held is string then return held end
  error(mismatch("text", index, kind, "text"), 2)
end

function Stored.blob(self: Stored, index: integer): string
  local kind, held = cell_at(self, index, "blob")
  if kind == "blob" and held is string then return held end
  error(mismatch("blob", index, kind, "a blob"), 2)
end

function Stored.bytes(self: Stored, index: integer): string
  local kind, held = cell_at(self, index, "bytes")
  if held is string then return held end
  error(mismatch("bytes", index, kind, "text or a blob"), 2)
end

function Stored.as_text(self: Stored, index: integer): string?
  local _, held = cell_at(self, index, "as_text")
  if held is string then return held end
  if held is integer then return string.format("%d", held) end
  if held is number then return sqlite.number_text(held) end
  return nil
end

function Stored.texts(self: Stored): {string}
  local out: mut {string} = {}
  for index = 1, #self // 2 do
    local kind, held = cell_at(self, index, "texts")
    if kind == "text" and held is string then
      out[#out + 1] = held
    else
      error(mismatch("texts", index, kind, "text"), 2)
    end
  end
  return out
end

function Stored.as_texts(self: Stored): {string}
  local out: mut {string} = {}
  for index = 1, #self // 2 do out[index] = self:as_text(index) or "" end
  return out
end

function Stored.value(self: Stored, index: integer): raw_sqlite.Value
  local kind, held = cell_at(self, index, "value")
  if held is integer then return { integer = held } end
  if held is number then return { number = held } end
  if held is string then
    if kind == "blob" then return { blob = held } end
    return { text = held }
  end
  return {}
end

--- The row `statement` was just stepped to, as typed cells in column
--- order, or, `as_text`, as the bytes of each column, each a "text" cell.
--- Its columns are asked after each step: a schema change re-prepares the
--- statement, and its columns with it.
local function cells_of(statement: raw_sqlite.Statement, as_text?: boolean): Row
  -- The core builds the whole row in one call ([`raw_sqlite.Statement.row`]), as the loop over its columns here did.
  local row: Stored = statement:row(stored_mt, as_text)
  return row as Row -- checked: cast_refused
end

--- The row `statement` was just stepped to, every column a "text" cell of
--- its bytes, as [`Handle.text_rows`] returns it.
local function texts_of(statement: raw_sqlite.Statement): Row
  return cells_of(statement, true)
end

--- The failure SQLite returned as `outcome`, its codes kept.
local function failed(outcome: raw_sqlite.Outcome): Failure
  local reason = if outcome.reason ~= "" then outcome.reason else "sqlite: the call failed" end
  local kind: Failure.Kind = if outcome.timed_out == true then "timeout" elseif outcome.cancelled == true then
    "cancelled" else "library" end
  return Failure.coded(reason, outcome.code, outcome.extended_code, kind)
end

--- SQLite's code for a lock another connection holds.
local BUSY <const> = 5

--- The first pause of a wait at a lock in a task, and the longest: each
--- pause doubles, as the core's busy handler's do.
local FIRST_PAUSE <const> = 1000000
local LONGEST_PAUSE <const> = 50000000

--- How a call the core returned BUSY for without waiting goes on: "again"
--- once this task has paused, "blocks" where the caller cannot park
--- (no task of [`Poll.run`], or one being killed), "spent" once the
--- handle's wait has passed, and "cancelled" where the task was
--- cancelled in a pause.
local enum Turn
  "again"
  "blocks"
  "spent"
  "cancelled"
end

--- A task's wait at another connection's lock: when it ends, and the
--- next pause.
local record Pause
  deadline: integer
  mut ns: integer
end

--- The monotonic clock, in nanoseconds, as cosmic.clock's
--- `monotonic_ns` reads it: the test harness reaches this module, so it
--- reads the raw binding rather than require cosmic.clock.
local function now_ns(): integer
  return (assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)))
end

local function pause_for(wait_ns: integer): Pause
  return { deadline = now_ns() + wait_ns, ns = FIRST_PAUSE }
end

--- One pause of `pause`, where the task parks and the others run, and
--- how the call goes on after it ([`Turn`]).
local function paused(pause: Pause): Turn
  local parks, delay = Waits.parks, Waits.delay
  if parks == nil or delay == nil or not parks() then return "blocks" end
  local left = pause.deadline - now_ns()
  if left <= 0 then return "spent" end
  local waited, _ = delay(math.min(pause.ns, left))
  if not waited then return "cancelled" end
  pause.ns = math.min(pause.ns * 2, LONGEST_PAUSE)
  return "again"
end

local CANCELLED_WAIT <const> = "sqlite: the task was cancelled while it waited at a lock"

--- `statement` stepped once, as [`raw_sqlite.Statement.step_result`] does.
--- In a task of [`Poll.run`], a step that meets another connection's
--- lock before the run's first row waits by parking the task, so the
--- others run, and steps again, for as long as the handle waits
--- ([`Handle.busy_timeout`]); anywhere else the core waits, holding the thread.
local function stepped(statement: raw_sqlite.Statement): string | raw_sqlite.ExecResult
  local state = statement:step_result()
  if state is string or state.parked ~= true then return state end
  local pause = pause_for(statement:wait_ns())
  while true do
    local turn = paused(pause)
    if turn == "spent" then return state end
    if turn == "cancelled" then
      return { code = BUSY, extended_code = BUSY, reason = CANCELLED_WAIT, cancelled = true }
    end
    state = statement:step_result(turn == "blocks")
    if state is string or state.parked ~= true then return state end
  end
end

--- Steps `statement` once and gives `project` the row it stands on: the
--- projection, or `nil` and nil when the statement is done, or `nil` and
--- why when the step failed. [`Handle.rows`], [`Handle.text_rows`],
--- [`Handle.map`] and [`Handle.query`] all step through it, so they agree
--- on what a failure says.
local function step_row<T>(statement: raw_sqlite.Statement,
                           project: function(raw_sqlite.Statement): T): T?, Failure?
  local state = stepped(statement)
  if state is raw_sqlite.ExecResult then return nil, failed(state) end
  if state == "done" then return nil, nil end
  return project(statement), nil
end

-- How an object of this module is made: see the note on objects in
-- cosmic/stream.tl.

--- SQLite's result codes this module's functions return of their own: a
--- library routine used against its contract, and a parameter at no
--- position the statement has.
local MISUSE <const> = 21
local RANGE <const> = 25
local OK <const> = 0
local ERROR <const> = 1

--- How [`Handle.transact`] begins a transaction: SQLite's `BEGIN DEFERRED`,
--- `BEGIN IMMEDIATE` or `BEGIN EXCLUSIVE`.
local enum Begin
  "deferred"
  "immediate"
  "exclusive"
end

--- The statement that begins a transaction each [`Begin`] names.
local BEGINS <const>: {Begin: string} = {
  deferred = "BEGIN DEFERRED", immediate = "BEGIN IMMEDIATE", exclusive = "BEGIN EXCLUSIVE",
}

--- How hard SQLite works to keep a commit through a power loss: its
--- `PRAGMA synchronous`. "full" syncs the journal at every commit; in
--- write-ahead mode "normal" syncs only at a checkpoint, so a power loss
--- can undo the last commits but never corrupts the file; "off" never
--- syncs; "extra" also syncs the directory a deleted journal was in.
local enum Synchronous
  "off"
  "normal"
  "full"
  "extra"
end

--- One step of [`Handle.migrate`]: SQL that [`Handle.exec`] runs, or work
--- on the handle that returns as [`Handle.transact`]'s work does.
local type Migration = string | function(Handle): (true) | (false, Failure)

--- The value `PRAGMA synchronous` takes for each [`Synchronous`].
local SYNCHRONOUS <const>: {Synchronous: string} = { off = "OFF", normal = "NORMAL", full = "FULL", extra = "EXTRA" }

--- Whether a [`Statement`] is still open: a query on it rewinds it as
--- the query ends, unless it was closed first.
local record Kept
  --- Whether the statement is closed.
  mut closed: boolean
  --- Whether a query on it is still reading its rows.
  mut busy: boolean
end

--- Ends `query`'s statement, once: a statement a [`Statement`] holds
--- is rewound for its next run, unless that was closed, and any other
--- is finalized.
local function finish(query: Query)
  if not query.open then return end
  query.open = false
  local kept = query.kept
  if kept ~= nil then kept.busy = false end
  if kept ~= nil and kept.closed then return end
  local statement = query.statement
  -- Ended early, on a row: a write (`INSERT ... RETURNING`) in
  -- autocommit commits at this reset, and a failure there (a deferred
  -- foreign key, a full disk) is the query's.
  if not query.ended and query.failed == nil then
    local reset = statement:reset_result()
    if reset.code ~= OK then query.failed = failed(reset) end
  elseif kept ~= nil then
    local _, _ = statement:reset()
  end
  if kept == nil then statement:finalize() end
end

--- A query's rows read one at a time: see [`Handle.query`]. It is a class,
--- so a query is held in a `<close>` variable.
local class Query
  --- Internal: the prepared statement the rows are read from. No caller
  --- reads or writes it.
  statement: raw_sqlite.Statement
  --- Internal: whether the statement is still unfinalized. No caller reads
  --- or writes it.
  mut open: boolean
  --- Internal: the [`Statement`] that holds the statement, where one
  --- does, so the end of the rows rewinds it rather than finalizing it.
  --- No caller reads or writes it.
  kept?: Kept
  --- Internal: whether the last row has been read. No caller reads or
  --- writes it.
  mut ended: boolean
  --- Internal: why stepping failed, nil until it does. No caller reads or
  --- writes it; [`Query.failure`] returns it.
  mut failed?: Failure

  --- The next row; nil and nil after the last; nil and why when
  --- stepping failed, the same again on every later read.
  function read(self): Row?, Failure?
    local earlier = self.failed
    if earlier ~= nil then return nil, earlier end
    if self.ended then return nil, nil end
    if not self.open then return nil, Failure.coded("sqlite: the query is closed", MISUSE) end
    local kept = self.kept
    if kept ~= nil and kept.closed then
      local closed = Failure.coded("sqlite: the query's statement is closed", MISUSE)
      self.failed = closed
      finish(self)
      return nil, closed
    end
    local row, failure = step_row(self.statement, cells_of)
    if row == nil then
      if failure == nil then
        self.ended = true
      else
        self.failed = failure
      end
      finish(self)
      return nil, failure
    end
    return row, nil
  end

  --- An iterator for a `for` loop over the rows still to come. It
  --- ends at the last one or at a failure, which `failure` then says.
  function each(self): function(): Row?
    return function(): Row?
      local row, _ = self:read()
      return row
    end
  end

  --- Why the rows ended early, or nil when they have not: after an
  --- `each` loop that ran out, nil means every row was read. A `break`,
  --- or a `close` inside the loop, ends it early with no failure of its
  --- own; a statement that writes, closed so, can fail as it commits,
  --- which this then returns.
  function failure(self): Failure?
    return self.failed
  end

  --- Finalizes the statement, so the handle can close; the last
  --- row, a failure and a `<close>` variable each do it too. A read
  --- afterward fails. Returns `true`, or `false` and why the rows
  --- failed ([`Query.failure`]): a write that returns rows
  --- (`INSERT ... RETURNING`) closed before its last row commits here
  --- in autocommit, and can fail. Closing again returns the same. A
  --- `<close>` variable drops that result: close such a write by hand.
  function close(self): (true) | (false, Failure)
    finish(self)
    local failure = self.failed
    if failure ~= nil then return false, failure end
    return true
  end

  function __close(self)
    local _, _ = self:close()
  end
end

--- The values of a statement given none: each parameter it has is unbound.
local NO_VALUES <const>: {raw_sqlite.Param} = {}

--- Why [`raw_sqlite.Statement.bind_all`] refused a value at `at`, in
--- words: position 0 is the list as a whole, which holds a key past the
--- last parameter or no position at all. With SQLite's code it is a
--- Failure; with none, the caller of the public method raises it.
local function bind_refusal(at: integer, why: string?): string
  if at == 0 then return "sqlite: " .. tostring(why) end
  return "sqlite: parameter " .. tostring(at) .. tostring(why)
end

--- `sql` prepared on `handle` with `values` bound, or nil and why; a
--- statement that does not bind is released. A kept statement whose table
--- has gone fails with "no such table" at its step, after its binding, and
--- not at its prepare.
local function prepared(handle: raw_sqlite.Handle, sql: string,
                        given?: {raw_sqlite.Param}, unbound?: boolean,
                        cached?: boolean): (raw_sqlite.Statement) | (nil, Failure)
  -- The core's `prepare_result` raises for SQL it refuses before SQLite
  -- reads it (a NUL, no statement, more than one), where `prepare`
  -- returns nil and why; any other raise (a closed handle) `prepare`
  -- raises again.
  -- `cached`, the statement is one the handle kept from a `release` of
  -- the same SQL where it kept one, which skips SQLite's prepare.
  local prepare = handle.prepare_result
  if cached == true then prepare = handle.prepare_cached_result end
  local called, opened = pcall(prepare, handle, sql)
  if not called then
    local statement, why = handle:prepare(sql)
    if statement ~= nil then
      statement:finalize()
      error(opened, 0)
    end
    return nil, Failure.coded("sqlite: " .. why, MISUSE)
  end
  -- Reading the schema can meet a lock too: wait as `stepped` does. SQL
  -- the first call took raises again only for a handle closed since.
  local outcome: raw_sqlite.PrepareResult = opened
  if outcome.parked == true then
    local pause = pause_for(handle:wait_ns())
    while outcome.parked == true do
      local turn = paused(pause)
      if turn == "spent" then break end
      if turn == "cancelled" then
        return nil, Failure.coded(CANCELLED_WAIT, BUSY, BUSY, "cancelled")
      end
      outcome = prepare(handle, sql, turn == "blocks")
    end
  end
  if outcome.code ~= OK then return nil, failed(outcome) end
  local statement = outcome.statement
  if unbound == true then return statement end
  local at, why, code = statement:bind_all(given or NO_VALUES)
  if at == nil then return statement end
  statement:release()
  local said = bind_refusal(at, why)
  if code is integer then return nil, Failure.coded(said, code) end
  error(said, 3)
end

--- `sql`, one statement that binds nothing and yields no row, run once
--- on `handle` through its kept statements: nil, or why it failed.
local function executed(handle: raw_sqlite.Handle, sql: string): Failure?
  local statement, trouble = prepared(handle, sql, nil, true, true)
  if statement == nil then return trouble end
  local state = stepped(statement)
  statement:release()
  if state is raw_sqlite.ExecResult then return failed(state) end
  return nil
end

--- Every row of `statement` as `project` gives it, and the statement
--- released ([`raw_sqlite.Statement.release`]): the rows, or `nil` and why a step failed.
local function each_row<T>(statement: raw_sqlite.Statement,
                           project: function(raw_sqlite.Statement): T): ({T}) | (nil, Failure)
  local out: mut {T} = {}
  while true do
    local row, failure = step_row(statement, project)
    if row == nil then
      statement:release()
      if failure ~= nil then return nil, failure end
      return out
    end
    out[#out + 1] = row
  end
end

--- `values` bound to `statement`, which a [`Statement`] holds, or why
--- not: nil where every value is bound. A refusal rewinds the statement,
--- its bindings cleared; a value of no shape a parameter takes raises at
--- the caller of the method that calls this.
local function bound_to(statement: raw_sqlite.Statement, values?: {raw_sqlite.Param}): Failure?
  local at, why, code = statement:bind_all(values or NO_VALUES)
  if at == nil then return nil end
  local _, _ = statement:reset()
  local said = bind_refusal(at, why)
  if code is integer then return Failure.coded(said, code) end
  error(said, 3)
end

--- Why `kept`'s statement cannot run now: a query on it is still
--- reading, and a run would rebind or step the rows under it. Nil where
--- it can.
local function held_by_query(kept: Kept): Failure?
  if kept.busy then
    return Failure.coded("sqlite: the statement's query is still open: read it to its end or close it first",
      MISUSE)
  end
  return nil
end

--- Rewinds `statement` after a run that stood on `row`, its bindings
--- cleared: why the run failed where it stopped before its end and, in
--- autocommit, committed at this rewind.
local function rewound(statement: raw_sqlite.Statement, row: boolean): Failure?
  if not row then
    local _, _ = statement:reset()
    return nil
  end
  local reset = statement:reset_result()
  if reset.code ~= OK then return failed(reset) end
  return nil
end

--- One statement compiled once and run many times with new values, as
--- [`Handle.prepare`] returns it: for a loop that runs the same SQL so
--- often that preparing it each time shows. Each call binds every
--- parameter from its `values`, as [`Handle.run`]'s contract says, and
--- leaves the statement rewound with no value bound. Close it when done,
--- or hold it in a `<close>` variable; the handle cannot close while one
--- is open.
---
---     local insert <close> = assert(db:prepare("INSERT INTO t (owner, n) VALUES (?1, ?2)"))
---     for n = 1, 3 do assert(insert:run({ "me", n })) end
local class Statement
  --- Internal: the compiled statement. No caller reads or writes it.
  statement: raw_sqlite.Statement
  --- Internal: whether it is closed, which a query on it reads. No
  --- caller reads or writes it.
  kept: Kept

  --- Runs the statement, as [`Handle.run`] does: `true`, or `false` and why.
  function run(self, values?: {raw_sqlite.Param}): (true) | (false, Failure)
    local held = held_by_query(self.kept)
    if held ~= nil then return false, held end
    local statement = self.statement
    local trouble = bound_to(statement, values)
    if trouble ~= nil then return false, trouble end
    local state = stepped(statement)
    if state is raw_sqlite.ExecResult then
      local _, _ = statement:reset()
      return false, failed(state)
    end
    local ended = rewound(statement, state == "row")
    if ended ~= nil then return false, ended end
    return true
  end

  --- Every row the statement yields, as [`Handle.rows`] reads them: the
  --- rows, or `nil` and why.
  function rows(self, values?: {raw_sqlite.Param}): ({Row}) | (nil, Failure)
    local held = held_by_query(self.kept)
    if held ~= nil then return nil, held end
    local statement = self.statement
    local trouble = bound_to(statement, values)
    if trouble ~= nil then return nil, trouble end
    local out: mut {Row} = {}
    while true do
      local row, failure = step_row(statement, cells_of)
      if row == nil then
        local _, _ = statement:reset()
        if failure ~= nil then return nil, failure end
        return out
      end
      out[#out + 1] = row
    end
  end

  --- The first row the statement yields, as [`Handle.one`] reads it: the
  --- row, `nil` alone where it yields none, or `nil` and why.
  function one(self, values?: {raw_sqlite.Param}): (Row) | (nil, Failure?)
    local held = held_by_query(self.kept)
    if held ~= nil then return nil, held end
    local statement = self.statement
    local trouble = bound_to(statement, values)
    if trouble ~= nil then return nil, trouble end
    local row, failure = step_row(statement, cells_of)
    local ended = rewound(statement, row ~= nil)
    if ended ~= nil then return nil, ended end
    if row ~= nil then return row end
    return nil, failure
  end

  --- The statement's rows read one at a time, as [`Handle.query`] reads
  --- them. Until the query ends or is closed the statement is running,
  --- and another call on it fails, saying why ([`Sqlite.MISUSE`]);
  --- closing the statement first ends the query, whose next read fails,
  --- saying why.
  function query(self, values?: {raw_sqlite.Param}): (Query) | (nil, Failure)
    local held = held_by_query(self.kept)
    if held ~= nil then return nil, held end
    local statement = self.statement
    local trouble = bound_to(statement, values)
    if trouble ~= nil then return nil, trouble end
    self.kept.busy = true
    local q: Query = { statement = statement, open = true, ended = false, failed = nil, kept = self.kept }
    return q
  end

  --- How many values a run takes: the highest parameter index, counting
  --- the gaps a `?NNN` leaves.
  function parameters(self): integer
    return self.statement:parameters()
  end

  --- The name of each column a row has, in order: its `AS` alias, or what
  --- SQLite calls it without one. Known before any row.
  function names(self): {string}
    local statement = self.statement
    local out: mut {string} = {}
    for index = 0, statement:columns() - 1 do out[#out + 1] = statement:name(index) end
    return out
  end

  --- Finalizes the statement, so the handle can close. Closing again does
  --- nothing; any other call afterward raises.
  function close(self)
    self.kept.closed = true
    self.statement:finalize()
  end

  function __close(self)
    self:close()
  end
end

--- An open database, as [`Sqlite.open`] and [`Sqlite.memory`] return it.
--- Every method that can fail returns `nil` or `false` and a [`Failure`]
--- with SQLite's codes (`code` and `extended_code`, and the kind
--- "cancelled" for a wait or call the handle's guard stopped, and
--- "timeout" for one past [`Handle.time_limit`]). A call on a
--- closed handle raises. Hold it in a `<close>` variable to close it on
--- the way out of a block.
local class Handle
  --- Internal: the connection the core holds. No caller reads or
  --- writes it.
  connection: raw_sqlite.Handle

  --- Runs every statement in `sql`, discarding any rows, with no
  --- parameter binding: schema DDL, PRAGMAs, or several `;`-separated
  --- statements in one call, which [`Handle.run`], [`Handle.rows`] and
  --- the others cannot do, since each prepares exactly one statement.
  --- No statement is retried: an earlier statement may already have
  --- changed the database when a later one fails. For SQL holding a NUL
  --- it returns false and why ([`Sqlite.MISUSE`]).
  function exec(self, sql: string): (true) | (false, Failure)
    if sql:find("\0", 1, true) ~= nil then
      return false, Failure.coded("sqlite: the SQL holds a NUL", MISUSE)
    end
    local outcome = self.connection:exec_result(sql)
    if outcome.code ~= OK then return false, failed(outcome) end
    return true
  end

  --- Runs a statement that yields no rows: it returns `true`, or
  --- `false` and why.
  ---
  --- `values` is a dense list of [`Sqlite.Param`] indexed by SQLite's
  --- parameter index, through its highest index: `{ 1, "a" }` for `?1`
  --- and `?2`. Repeated named parameters share an index, and a gap in
  --- `?NNN` numbers still needs an entry (use [`Sqlite.NULL`]). A missing
  --- entry or a position past the last parameter makes it return `false`
  --- and why ([`Sqlite.RANGE`]). A value of no type a parameter takes (a
  --- function, a malformed [`Sqlite.Value`]) raises, as does a key that
  --- is no position from 1; the statement is released first.
  function run(self, sql: string, values?: {raw_sqlite.Param}): (true) | (false, Failure)
    local statement, trouble = prepared(self.connection, sql, values, false, true)
    if statement == nil then return false, trouble end
    local state = stepped(statement)
    if state == "row" then
      -- A write with RETURNING stopped at its first row commits at this
      -- reset in autocommit, which returns a failure of the commit.
      local reset = statement:reset_result()
      statement:release()
      if reset.code ~= OK then return false, failed(reset) end
      return true
    end
    statement:release()
    if state is raw_sqlite.ExecResult then return false, failed(state) end
    return true
  end

  --- The first row a query yields, as [`Handle.rows`] reads it: the row,
  --- `nil` alone where the query yields none, or `nil` and why; an
  --- `assert` of a query that yields none fails with no message. A query
  --- stops at the first row, so rows past it are never read; a write with
  --- `RETURNING` makes all its changes, and its first row is returned.
  --- A failure where the statement commits (a deferred foreign key) is
  --- why. `values` follows [`Handle.run`]'s contract.
  ---
  ---     local row = assert(db:one("SELECT count(*) FROM t"))
  ---     print(row:integer(1))
  ---     local found, why = db:one("SELECT body FROM t WHERE id = ?1", { id })
  ---     if found == nil and why ~= nil then return nil, why end
  function one(self, sql: string, values?: {raw_sqlite.Param}): (Row) | (nil, Failure?)
    local statement, trouble = prepared(self.connection, sql, values, false, true)
    if statement == nil then return nil, trouble end
    local row, failure = step_row(statement, cells_of)
    if row ~= nil then
      -- Stopped before its end, so in autocommit the statement commits at
      -- this reset, which returns a failure of the commit.
      local reset = statement:reset_result()
      statement:release()
      if reset.code ~= OK then return nil, failed(reset) end
      return row
    end
    statement:release()
    return nil, failure
  end

  --- Every row a query yields, each a [`Sqlite.Row`] that keeps its
  --- columns' SQLite types. Returns the rows, or `nil` and why. `values`
  --- follows [`Handle.run`]'s contract.
  function rows(self, sql: string, values?: {raw_sqlite.Param}): ({Row}) | (nil, Failure)
    local statement, trouble = prepared(self.connection, sql, values, false, true)
    if statement == nil then return nil, trouble end
    return each_row(statement, cells_of)
  end

  --- Every row a query yields as `project` makes it: the list of what
  --- `project` returned for each row in turn, or `nil` and why.
  --- `project` reads the row's columns (`r:text(1)`) and returns one
  --- value, which is how a caller builds a record per row; a nil raises. A
  --- raise inside `project`, such as a column of another type than it
  --- read, leaves nothing open and reaches the caller. `values` follows
  --- [`Handle.run`]'s contract, and is nil where the query takes none.
  ---
  ---     local record Named
  ---       name: string
  ---       n: integer
  ---     end
  ---     local db = assert(Sqlite.memory())
  ---     assert(db:exec("CREATE TABLE t (name TEXT, n INTEGER); INSERT INTO t VALUES ('a', 1), ('b', 2)"))
  ---     local found = assert(db:map("SELECT name, n FROM t WHERE n > ?1 ORDER BY n",
  ---       { 0 }, function(r: Sqlite.Row): Named
  ---         return { name = r:text(1), n = r:integer(2) }
  ---       end))
  ---     print(#found, found[2].name) -- 2  b
  function map<T>(self, sql: string, values: {raw_sqlite.Param}?,
                  project: function(Row): T): ({T}) | (nil, Failure)
    local statement, trouble = prepared(self.connection, sql, values, false, true)
    if statement == nil then return nil, trouble end
    local out: mut {T} = {}
    while true do
      local state = stepped(statement)
      if state is raw_sqlite.ExecResult then
        statement:release()
        return nil, failed(state)
      end
      if state == "done" then
        statement:release()
        return out
      end
      local called, made = pcall(project, cells_of(statement))
      if not called then
        statement:release()
        error(made, 0)
      end
      if made == nil then
        statement:release()
        error("sqlite: map: project answered nil for a row; answer a value", 2)
      end
      out[#out + 1] = made
    end
  end

  --- A query whose rows are read one at a time, as `rows` gives them
  --- but never all held at once: nil and why when the statement does
  --- not prepare or bind (`values` follows [`Handle.run`]'s contract).
  --- The statement stays open, and the handle cannot close, until the
  --- last row is read, a step fails, or the query is closed; hold it in
  --- a `<close>` variable to close it on a `break` or an error too.
  ---
  --- An open query holds SQLite's read lock on a file database between
  --- reads, so a writer on another connection waits for it (in rollback
  --- mode, up to the busy timeout, then fails): read it out promptly. A
  --- write on the same connection to a table the query reads may be
  --- read back by it, without end for an insert into a table scanned
  --- whole; collect what to write first. The statement runs at the
  --- first read, not before: [`Handle.run`] is for one that yields no
  --- rows.
  ---
  ---     local q <close> = assert(db:query("SELECT id, body FROM t"))
  ---     for row in q:each() do print(row:integer(1), row:text(2)) end
  ---     assert(q:failure() == nil, q:failure())
  function query(self, sql: string, values?: {raw_sqlite.Param}): (Query) | (nil, Failure)
    local opened, trouble = prepared(self.connection, sql, values)
    if opened == nil then return nil, trouble end
    local q: Query = { statement = opened, open = true, ended = false, failed = nil, kept = nil }
    return q
  end

  --- A direct text projection for callers whose SQL already defines the
  --- coercion they want. Every column of every row is text, read with
  --- `row:text(i)`: SQLite's byte representation is returned for every
  --- value: NULL, empty text and empty blob all become `""`; integers
  --- and floats use SQLite's text formatting; text and blobs remain byte
  --- strings, including NUL. On such a row `kind` returns `"text"` for
  --- every column and [`Row.is_null`] returns false, and `integer`,
  --- `number` and `blob` raise: read those from [`Handle.rows`].
  function text_rows(self, sql: string, values?: {raw_sqlite.Param}): ({Row}) | (nil, Failure)
    local statement, trouble = prepared(self.connection, sql, values, false, true)
    if statement == nil then return nil, trouble end
    return each_row(statement, texts_of)
  end

  --- Brings the database's schema up to date: `steps[k]` makes version
  --- `k` from version `k - 1`, as SQL that [`Handle.exec`] runs (any
  --- number of statements) or as work on the handle. The version is the
  --- database's `PRAGMA user_version`. A database at `#steps` returns at
  --- once, with no lock taken. Otherwise the steps past its version run
  --- in order in one transaction ([`Handle.transact`]: two processes that
  --- open the database at once take turns, and the second finds the
  --- first's work done), which then sets the version to `#steps`.
  --- Returns that version, or `nil` and why, with nothing changed, for:
  ---
  --- - a step that fails, named by its number, with the step's code
  ---   (one that raises rolls back too, and its error is raised again);
  --- - a version past `#steps` (a newer program's database), or below 0;
  --- - version 0 on a database that holds a schema already (a table,
  ---   index, view or trigger): another program's, or one made before it
  ---   used `migrate`. Set its `user_version` to the step it is at, once,
  ---   to adopt it.
  ---
  --- A refusal of the database has no `code`. Add steps only at the
  --- end: a step that has run on a database never runs on it again, so
  --- a changed step changes nothing there. A step runs inside the
  --- transaction, so it must not `BEGIN`, `COMMIT` or `ROLLBACK` (one
  --- that ends the transaction fails, named), its `PRAGMA user_version`
  --- is overwritten, and what SQLite refuses or ignores inside a
  --- transaction (`VACUUM`, `PRAGMA foreign_keys`) is no step: set
  --- `foreign_keys` off around the call to rebuild a table.
  ---
  ---     local version, why = db:migrate({
  ---       "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)",
  ---       "ALTER TABLE notes ADD COLUMN made INTEGER",
  ---     })
  function migrate(self, steps: {Migration}): (integer) | (nil, Failure)
    local wanted = #steps
    local function counted(sql: string): (integer) | (nil, Failure)
      local rows, why = self:rows(sql)
      if rows == nil then return nil, why end
      local row = rows[1]
      if row == nil then return nil, Failure.new("sqlite: migrate: " .. sql .. " gave no row") end
      return row:integer(1)
    end
    local function refusal(at: integer): Failure?
      if at > wanted or at < 0 then
        return Failure.new(("sqlite: migrate: the database's schema is version %d, and the steps given end at " ..
          "version %d: another program, or a newer one, made it"):format(at, wanted))
      end
      return nil
    end
    local function run_step(step: Migration): (true) | (false, Failure)
      if step is string then return self:exec(step) end
      return step(self)
    end
    -- Read first, with no lock: a database at its version, the usual
    -- case, waits behind no writer.
    local first, first_why = counted("PRAGMA user_version")
    if first == nil then return nil, first_why end
    local early = refusal(first)
    if early ~= nil then return nil, early end
    if first == wanted then return wanted end
    local ok, why = self:transact(function(): (true) | (false, Failure)
      local at, at_why = counted("PRAGMA user_version")
      if at == nil then return false, at_why end
      local refused = refusal(at)
      if refused ~= nil then return false, refused end
      if at == wanted then return true end
      if at == 0 then
        local objects, objects_why = counted("SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\'")
        if objects == nil then return false, objects_why end
        if objects ~= 0 then
          return false, Failure.new("sqlite: migrate: the database holds a schema but no version (user_version 0): " ..
              "another program's database, or one made before migrate; set PRAGMA user_version to the step it is " ..
              "at to adopt it")
        end
      end
      for k, step in ipairs(steps) do
        if k > at then
          local done, step_why = run_step(step)
          if not done then
            local said = ("sqlite: migrate: step %d: %s"):format(k, tostring(step_why))
            if step_why.code == nil then return false, Failure.new(said) end
            return false, Failure.coded(said, step_why.code, step_why.extended_code, step_why.kind)
          end
          if not self:in_transaction() then
            return false, Failure.new(("sqlite: migrate: step %d ended the transaction with a COMMIT or ROLLBACK " ..
              "of its own, so what it wrote is not undone; no step after it ran"):format(k))
          end
        end
      end
      return self:exec(("PRAGMA user_version = %d"):format(wanted))
    end)
    if not ok then return nil, why end
    return wanted
  end

  --- Whether a transaction is open on the handle: a [`Handle.transact`]
  --- running, or a `BEGIN` or `SAVEPOINT` not yet committed or rolled
  --- back.
  function in_transaction(self): boolean
    return self.connection:in_transaction()
  end

  --- Runs `work` inside a transaction and commits when it returns
  --- `true`. When `work` returns `false` and a [`Failure`], or the
  --- commit fails, the transaction rolls back and this returns `false`
  --- and that failure (one that says the work gave no why, where it gave
  --- none). When `work` raises, the transaction rolls back and the same
  --- error is raised again.
  ---
  --- On a writable handle the transaction begins `IMMEDIATE`: it takes
  --- the write lock at once, waiting for it as [`Handle.busy_timeout`]
  --- says, so work that reads and then writes never fails part way with
  --- [`Sqlite.BUSY`] because another connection wrote between the two,
  --- which a deferred transaction in write-ahead mode can, without
  --- waiting. On a read-only handle it begins `DEFERRED`, which takes a
  --- read snapshot at its first read. `begin` names another
  --- ("deferred", "immediate" or "exclusive"; any other raises): work
  --- that only reads on a writable handle passes "deferred", so it does
  --- not wait behind a writer. A handle held to queries
  --- ([`Handle.reads_only`]) refuses every transaction.
  ---
  --- Called while a transaction is open on the handle, inside another
  --- `transact` or after a `BEGIN`, it nests: the work runs inside a
  --- `SAVEPOINT`, which a failure rolls back alone, and which commits
  --- with the transaction around it. So a function that writes in a
  --- transaction of its own can be called from inside a caller's. A
  --- nested call ignores `begin`: the outer transaction has begun, and
  --- holds the locks its own mode took.
  ---
  --- Work must not end its transaction itself, with a `COMMIT` or
  --- `ROLLBACK`: this returns `false` and says so. Some failures end
  --- it too (`INSERT OR ROLLBACK`, a trigger's `RAISE(ROLLBACK)`, a
  --- full disk). Where either ends the transaction around a nested call,
  --- the nested call raises, so the caller's work stops before what it
  --- writes after commits on its own.
  ---
  --- `DETACH` of an attached database fails with "database X is locked"
  --- while a transaction that read that database is open. `ATTACH` it,
  --- `transact`, and `DETACH` once the transaction has committed.
  ---
  ---     local ok, why = db:transact(function(): (true) | (false, Failure)
  ---       local a, trouble = db:run("INSERT INTO t (body) VALUES (?1)", { "a" })
  ---       if not a then return false, trouble end
  ---       return db:run("INSERT INTO t (body) VALUES (?1)", { "b" })
  ---     end)
  function transact(self, work: function(): (true) | (false, Failure),
                    begin?: Begin): (true) | (false, Failure)
    local connection = self.connection
    local opening_begin: string? = if begin ~= nil then BEGINS[begin] else nil end
    if begin ~= nil and opening_begin == nil then
      error("sqlite: transact begins \"deferred\", \"immediate\" or \"exclusive\"", 2)
    end
    local nested = connection:in_transaction()
    local opening, undoing, closing: string, string, string
    if nested then
      opening, undoing, closing = "SAVEPOINT cosmic_transact", "ROLLBACK TO cosmic_transact", "RELEASE cosmic_transact"
    else
      local default = if connection:read_only() then "BEGIN DEFERRED" else "BEGIN IMMEDIATE" end
      opening, undoing, closing = opening_begin or default, "ROLLBACK", "COMMIT"
    end
    -- A savepoint rolled back to is still open: it ends at its release.
    -- The opening and the commit step a statement, so in a task of
    -- Poll.run a wait at another connection's lock parks the task.
    local function undo()
      local _ = connection:exec_result(undoing)
      if nested then
        local _ = connection:exec_result(closing)
      end
    end
    local started = executed(connection, opening)
    if started ~= nil then return false, started end
    local called, ok, why = pcall(function(): boolean, Failure?
      local done, trouble = work()
      return done, trouble
    end)
    if not called then
      undo()
      error(ok, 0)
    end
    -- Some failures roll back the whole transaction (`INSERT OR
    -- ROLLBACK`, a trigger's RAISE(ROLLBACK), a full disk), and work can
    -- end it with a COMMIT or ROLLBACK of its own. Nested, that ends the
    -- caller's transaction under it, and what the caller writes after
    -- would commit at once: raise, so the caller's work stops.
    local open = connection:in_transaction()
    if nested and not open then
      local cause = if ok then "the work ended it with a COMMIT or ROLLBACK of its own" else tostring(why) end
      error("sqlite: transact: the transaction around this one ended inside it: " .. cause, 0)
    end
    if not ok then
      undo()
      return false, why or Failure.new("sqlite: transact: the work failed and said no why")
    end
    if not open then
      return false, Failure.new("sqlite: transact: the work ended its transaction with a COMMIT or ROLLBACK of its own")
    end
    local committed = executed(connection, closing)
    if committed ~= nil then
      undo()
      return false, committed
    end
    return true
  end

  --- `sql`, which must hold exactly one statement, compiled once for a
  --- loop that runs it many times with new values: a [`Sqlite.Statement`],
  --- or nil and why. [`Handle.run`] and the others keep the statements of
  --- their recent SQL too; a [`Statement`] skips even finding it again.
  ---
  ---     local insert <close> = assert(db:prepare("INSERT INTO t (owner, n) VALUES (?1, ?2)"))
  ---     for n = 1, 3 do assert(insert:run({ "me", n })) end
  function prepare(self, sql: string): (Statement) | (nil, Failure)
    local statement, trouble = prepared(self.connection, sql, nil, true)
    if statement == nil then return nil, trouble end
    local kept: Statement = { statement = statement, kept = { closed = false, busy = false } }
    return kept
  end

  --- Switches the main database to write-ahead mode (`PRAGMA
  --- journal_mode = WAL`), so readers of the file read beside a writer.
  --- The switch needs the file to itself for a moment, and SQLite can
  --- refuse it as busy without waiting, so a busy refusal is tried again
  --- until the handle's wait ([`Handle.busy_timeout`]) has passed, or a
  --- signal the innermost guard caught stops it (a failure of kind
  --- "cancelled"). A memory or temporary database ([`Sqlite.memory()`], a
  --- path of `""`) has no file to keep a log beside, keeps the journal it
  --- has, and returns true too. Returns `false` and why when the switch
  --- failed: a read-only handle's file that is not in WAL mode returns
  --- SQLite's `SQLITE_READONLY` (8), and an immutable one says the mode stayed as it
  --- was. A borrowed handle raises.
  ---
  ---     local db = assert(Sqlite.open(path, { writable = true }))
  ---     assert(db:wal())
  function wal(self): (true) | (false, Failure)
    local outcome = self.connection:wal_result()
    if outcome.code ~= OK then return false, failed(outcome) end
    if outcome.mode ~= "wal" and not outcome.temporary then
      return false, Failure.coded("sqlite: the journal mode stayed " .. outcome.mode .. ", not wal", ERROR)
    end
    return true
  end

  --- Waits up to `timeout_ns` at locks, rounded up to milliseconds,
  --- checking the innermost guard's unread signal without taking it: a
  --- signal stops the wait, and the call returns a failure of kind
  --- "cancelled" with SQLite's code, usually [`Sqlite.BUSY`] (no
  --- rollback is implied). Each call shares one budget across its
  --- locking events, starting at the first contention. Zero never
  --- sleeps. A negative or noninteger duration raises, as does a
  --- borrowed handle. Without a guard, only the time limits it. A
  --- handle waits so for a minute until this sets another wait.
  --- `PRAGMA busy_timeout` reads zero for this handler; writing that
  --- pragma replaces it, and calling this again reinstalls it. SQLite
  --- can refuse a lock without calling any busy handler.
  ---
  --- In a task of [`Poll.run`], a query, a run, a prepare and the
  --- begin and commit of a [`Handle.transact`] that meet a lock wait by
  --- parking the task, so the other tasks run, for as long as this sets;
  --- a task cancelled in the wait fails of kind "cancelled". While one
  --- task waits so, another task's run or query on the same handle waits
  --- its turn behind it, and its `db:exec` fails [`Sqlite.BUSY`] at once.
  --- These hold the thread while they wait, as outside a task: a step
  --- after a query's first row, a PRAGMA (a checkpoint yields its busy
  --- row where the wait is declined), `db:exec`, a commit at the reset
  --- of a statement stopped on a row, [`Handle.wal`] and a borrowed
  --- handle. A write in rollback mode that parks gives up its claim on
  --- the lock between its tries, so steady readers can outlast its wait;
  --- in WAL mode ([`Handle.wal`]) readers take no such lock.
  function busy_timeout(self, timeout_ns: integer)
    self.connection:busy_timeout(timeout_ns)
  end

  --- Stops each later call that runs past `limit_ns` from its start,
  --- checked every 1000 of SQLite's steps: the call returns a failure
  --- of kind "timeout" with code [`Sqlite.INTERRUPT`]. While a limit is
  --- set, a signal the innermost guard catches stops a call too, of
  --- kind "cancelled". An interrupted write rolls back its transaction;
  --- a read leaves it open. Nil removes the limit, and a signal still
  --- stops a call. A negative duration raises, as does a borrowed
  --- handle.
  function time_limit(self, limit_ns: integer?)
    self.connection:time_limit(limit_ns)
  end

  --- Holds the handle to queries, for good: for SQL that someone else
  --- wrote, a person's at a prompt or a model's. Each statement is
  --- refused as it is prepared unless it is a `SELECT` (with the
  --- functions it calls and `WITH RECURSIVE`) or a PRAGMA that reads:
  --- the lists of tables, columns, indexes and foreign keys,
  --- `integrity_check` and `quick_check`, and a setting read without a
  --- value (`PRAGMA user_version`, not `PRAGMA user_version = 2`).
  --- `VACUUM` and `VACUUM INTO` are refused too. Behind that, `PRAGMA
  --- query_only` is set, so no write reaches a database as a statement
  --- runs, and nothing may be attached; raising the `"attached"` limit
  --- after raises. No SQL makes or writes a file, but SQLite itself may:
  --- opening a database in write-ahead mode makes its `-wal` and `-shm`
  --- files beside it where they are missing (`immutable` opens none).
  --- A refusal returns [`Sqlite.AUTH`] and says what was refused. Returns
  --- true, or false and why; calling it again does nothing. A borrowed
  --- handle, such as the store's, raises: the store holds its own to
  --- queries already. [`Sqlite.open`]'s `reads_only` does this as it opens.
  ---
  ---     local db = assert(Sqlite.open("notes.db", { reads_only = true }))
  ---     assert(db:rows("SELECT count(*) FROM t"))
  ---     local ok, why = db:run("DELETE FROM t")
  ---     print(ok, why.code == Sqlite.AUTH) -- false  true
  function reads_only(self): (true) | (false, Failure)
    local held, why = self.connection:reads_only()
    if not held then return false, Failure.coded("sqlite: " .. why, ERROR) end
    return true
  end

  --- Closes the connection: true, or false and why, [`Sqlite.BUSY`] as
  --- SQLite returns it, while a statement or query is still open.
  --- Closing one already closed does nothing. A borrowed handle, such as
  --- the store's, only lets go of it.
  function close(self): (true) | (false, Failure)
    local closed, why = self.connection:close()
    if not closed then return false, Failure.coded("sqlite: " .. why, BUSY) end
    return true
  end

  --- How many rows the most recent INSERT, UPDATE or DELETE on this
  --- connection changed: not the whole database's, and not another
  --- connection's.
  function changes(self): integer
    return self.connection:changes()
  end

  --- The rowid SQLite assigned the most recent successful INSERT on
  --- this connection: 0 before any has run on it, and a table declared
  --- `WITHOUT ROWID` never changes it.
  function last_insert_rowid(self): integer
    return self.connection:last_insert_rowid()
  end

  --- Sets one of the connection's limits, named as SQLite's
  --- `SQLITE_LIMIT_*` without the prefix, lower-cased (`"attached"`,
  --- `"sql_length"`, `"length"`, `"column"`, `"expr_depth"`,
  --- `"compound_select"`, `"vdbe_op"`, `"function_arg"`,
  --- `"like_pattern_length"`, `"variable_number"`, `"trigger_depth"`,
  --- `"worker_threads"`), and returns the value it had. A negative
  --- `value` changes nothing, so it reads the limit. A value above the
  --- library's own ceiling raises, naming the ceiling, as does an
  --- unknown name. `"attached"` starts at 10 and may be raised to 125.
  function limit(self, name: string, value: integer): integer
    return self.connection:limit(name, value)
  end

  function __close(self)
    local _, _ = self:close()
  end
end

--- A handle that holds `connection`.
local function handle_of(connection: raw_sqlite.Handle): Handle
  return { connection = connection }
end

--- A database's tables, declared as the DDL that creates them: see
--- [`Sqlite.schema`].
local record Schema
  --- The DDL, as given.
  ddl: string
end

--- One column of a table, as `pragma_table_xinfo` describes it.
local record Column
  name: string
  --- The declared type, in capitals; empty for a column declared with none.
  declared: string
  notnull: boolean
  --- Its place in the primary key, from 1; 0 for a column outside it.
  key: integer
  --- 0 for a plain column, 2 or 3 for a generated one (virtual or stored),
  --- 1 for a virtual table's hidden column.
  hidden: integer
end

--- Each declared type a column was read with, as [`type_spelled`] spells it.
local spelled_types: mut {string: string} = {}

--- The declared type `declared` as two that read the same spell it: in capitals, with one space between words and
--- none at a parenthesis or comma.
local function type_spelled(declared: string): string
  local known = spelled_types[declared]
  if known ~= nil then return known end
  local spaced = (declared:upper():gsub("%s+", " "))
  local spelled = (spaced:gsub(" ?([(),]) ?", "%1"):match("^ ?(.-) ?$")) or ""
  spelled_types[declared] = spelled
  return spelled
end

--- The user tables of `handle`'s main database and their columns, read in one statement: the tables' names in order
--- of name, and each one's columns, in order, by its name in lower case (SQLite's names are without case). With
--- `only`, the tables of those names alone: a table this process cannot read (a virtual table of a module it lacks) is
--- then no failure unless it is one of them.
local function tables_of(handle: Handle, only?: {string}): ({string}, {string: {Column}}) | (nil, Failure)
  local sql = 'SELECT m.name, p.name, p.type, p."notnull", p.pk, p.hidden ' ..
    "FROM main.sqlite_schema AS m, pragma_table_xinfo(m.name, 'main') AS p " ..
    "WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite\\_%' ESCAPE '\\' "
  local values: {raw_sqlite.Param} = {}
  if only ~= nil then
    -- As a JSON array of strings: a name of SQL holds no control character, so `"` and `\` are all to escape.
    local listed: mut {string} = {}
    for _, name in ipairs(only) do
      listed[#listed + 1] = '"' .. (name:gsub('[\\"]', "\\%0")) .. '"'
    end
    sql = sql .. "AND lower(m.name) IN (SELECT lower(value) FROM json_each(?1)) "
    values = { "[" .. table.concat(listed, ",") .. "]" }
  end
  local rows, why = handle:rows(sql .. "ORDER BY m.name, p.cid", values)
  if rows == nil then return nil, why end
  local names: mut {string} = {}
  local columns: mut {string: mut {Column}} = {}
  for _, row in ipairs(rows) do
    local name = row:text(1)
    local key = name:lower()
    local found = columns[key]
    local held: mut {Column} = if found ~= nil then found else {} end
    if found == nil then
      columns[key] = held
      names[#names + 1] = name
    end
    local column: Column = {
      name = row:text(2), declared = type_spelled(row:text(3)), notnull = row:integer(4) ~= 0, key = row:integer(5),
      hidden = row:integer(6),
    }
    held[#held + 1] = column
  end
  return names, columns
end

--- `columns` as the open failure names them: `(id INTEGER PRIMARY KEY 1, body TEXT NOT NULL)`.
local function column_list(columns: {Column}): string
  local parts: mut {string} = {}
  for _, column in ipairs(columns) do
    local words: mut {string} = { column.name }
    if column.declared ~= "" then words[#words + 1] = column.declared end
    if column.notnull then words[#words + 1] = "NOT NULL" end
    if column.key ~= 0 then words[#words + 1] = ("PRIMARY KEY %d"):format(column.key) end
    if column.hidden == 1 then words[#words + 1] = "HIDDEN" end
    if column.hidden == 2 then words[#words + 1] = "GENERATED VIRTUAL" end
    if column.hidden == 3 then words[#words + 1] = "GENERATED STORED" end
    parts[#parts + 1] = table.concat(words, " ")
  end
  return "(" .. table.concat(parts, ", ") .. ")"
end

--- Whether two column lists are the same, column for column.
local function same_columns(a: {Column}, b: {Column}): boolean
  if #a ~= #b then return false end
  for k, column in ipairs(a) do
    local other = assert(b[k])
    if column.name:lower() ~= other.name:lower() or column.declared ~= other.declared or column.notnull ~= other.notnull or
        column.key ~= other.key or column.hidden ~= other.hidden then
      return false
    end
  end
  return true
end

--- The tables a schema's DDL creates: their names in order, and each
--- one's columns.
local record SchemaTables
  mut names: mut {string}
  mut columns: mut {string: {Column}}
end

--- What each schema value's DDL creates, read once per value.
local declared_tables: mut {Schema: SchemaTables} = setmetatable({}, { __mode = "k" })

--- What `schema`'s DDL creates, read by running it in a memory
--- database the first time: raises, naming why, when SQLite refuses it
--- or it creates no table.
local function declared(schema: Schema): SchemaTables
  local known = declared_tables[schema]
  if known ~= nil then return known end
  local opened = sqlite.open_result(":memory:", true, nil, nil, true)
  if opened.code ~= OK then error("sqlite: schema: " .. tostring(failed(opened)), 0) end
  local handle <close> = handle_of(opened.handle)
  -- Nothing but this memory database is written: an `ATTACH` fails.
  local _ = handle:limit("attached", 0)
  local ran, why = handle:exec(schema.ddl)
  if not ran then error("sqlite: schema: the DDL fails: " .. tostring(why), 0) end
  local names, columns = assert(tables_of(handle))
  local found: SchemaTables = { names = {}, columns = {} }
  for _, name in ipairs(names) do
    found.names[#found.names + 1] = name
    found.columns[name] = assert(columns[name:lower()])
  end
  if #found.names == 0 then error("sqlite: schema: the DDL creates no table", 0) end
  declared_tables[schema] = found
  return found
end

--- Gives `handle`'s database the tables of `schema`, or checks that it
--- holds them. A database with no schema object at all is new: a
--- writable handle runs the DDL on it, in one transaction. Then each
--- table the DDL creates must be in the file with the same columns, in
--- the same order, of the same declared type, NOT NULL and key.
local function hold_schema(handle: Handle, path: string, schema: Schema, writable: boolean): (true) | (false, Failure)
  local wanted = declared(schema)
  local function objects(): (integer) | (nil, Failure)
    local row, why = handle:one("SELECT count(*) FROM main.sqlite_schema")
    if row == nil then return nil, why or Failure.new("sqlite: schema: the count gave no row") end
    return row:integer(1)
  end
  if writable then
    local count, why = objects()
    if count == nil then return false, why end
    if count == 0 then
      -- Counted again under the write lock: two processes that open a
      -- new file at once take turns, and the second finds the tables.
      local made, made_why = handle:transact(function(): (true) | (false, Failure)
        local now, now_why = objects()
        if now == nil then return false, now_why end
        if now ~= 0 then return true end
        local ran, ran_why = handle:exec(schema.ddl)
        if ran then return true end
        local said = ("sqlite: schema: the DDL fails on %s: %s"):format(path, ran_why.message)
        local code = ran_why.code
        if code == nil then return false, Failure.new(said) end
        return false, Failure.coded(said, code, ran_why.extended_code, ran_why.kind)
      end, "immediate")
      if not made then return false, made_why end
    end
  end
  local listed, held = tables_of(handle, wanted.names)
  if listed == nil then return false, held end
  local differences: mut {string} = {}
  for _, name in ipairs(wanted.names) do
    local has = held[name:lower()] or {}
    local want = assert(wanted.columns[name])
    if #has == 0 then
      differences[#differences + 1] = ("no table %s %s"):format(name, column_list(want))
    elseif not same_columns(has, want) then
      differences[#differences + 1] = ("table %s is %s where the schema declares %s"):format(name, column_list(has),
        column_list(want))
    end
  end
  if #differences == 0 then return true end
  return false, Failure.new(("sqlite: %s does not hold the schema: %s. A file another program made, or an older " ..
    "one: migrate it on a handle given no schema ([`Handle.migrate`]), then give it the schema"):format(path, table.concat(differences, "; ")))
end

local record Sqlite
  --- An open database, as `open` and `memory` return it, with the
  --- methods that query it: `cosmic docs Sqlite.Handle` lists them.
  type Handle = Handle
  --- One prepared statement, as [`Handle.prepare`] returns it.
  type Statement = Statement
  --- Internal: whether a statement is closed, which a query on it reads.
  --- No caller outside this module holds one.
  type Kept = Kept
  --- Successful execution.
  OK: integer
  --- Another connection prevents the operation; extended_code can
  --- distinguish cases such as a stale WAL snapshot requiring rollback.
  BUSY: integer
  --- This connection, or one sharing its cache, prevents the operation.
  LOCKED: integer
  --- The call was stopped before it ended: [`Handle.time_limit`] ran
  --- out, or a guard caught a signal.
  INTERRUPT: integer
  --- SQLite found a malformed database structure.
  CORRUPT: integer
  --- SQLite did not recognize a database file.
  NOTADB: integer
  --- A generic SQL failure: a statement SQLite refused, or a parameter
  --- that did not bind.
  ERROR: integer
  --- What the core refuses before SQLite reads it: SQL with no statement
  --- or more than one, a NUL in SQL or a path, a read of a closed query.
  MISUSE: integer
  --- A parameter at no position the statement has, or a position with
  --- no parameter.
  RANGE: integer
  --- A statement a handle held to queries refused ([`Handle.reads_only`]).
  AUTH: integer

  --- One parameter value, as a statement's `values` list holds it. An
  --- integer, a float or a string binds as itself, a string as text; a
  --- boolean binds as 1 or 0. A [`Sqlite.Value`] says what SQLite is told
  --- the value is: [`Sqlite.blob`] for bytes, [`Sqlite.NULL`] for SQL
  --- NULL, and the lists that `carray(?N)` reads. A `nil` in the list
  --- leaves its position with no value, which makes the call fail,
  --- saying why ([`Sqlite.RANGE`]): use [`Sqlite.NULL`].
  type Param = raw_sqlite.Param

  --- One tagged parameter value. Its field says what SQLite is told it
  --- is, so bytes bind as a blob and not as text. At most one field is
  --- allowed; an empty table explicitly binds SQL NULL. A value of
  --- another shape, or a table with a metatable (but [`Sqlite.NULL`]),
  --- raises where it is bound. A list in `integers`,
  --- `numbers`, `texts` or `blobs` is bound as an array that only
  --- `carray(?N)` reads, as a table of its elements: `x IN carray(?1)`
  --- tests membership in it. Used as a value, compared, stored or
  --- returned, it is NULL.
  type Value = raw_sqlite.Value

  --- The SQLite storage class of a result cell: see [`Sqlite.Row.kind`].
  type Kind = Kind

  --- How [`Handle.transact`] begins a transaction.
  type Begin = Begin

  --- How hard SQLite works to keep a commit through a power loss.
  type Synchronous = Synchronous

  --- One step of [`Handle.migrate`]: SQL, or work on the handle.
  type Migration = Migration

  --- How [`Sqlite.open`] opens a database.
  record OpenOptions
    --- Opens for reading and writing. Without it the database is read-only.
    writable?: boolean
    --- With `writable`, creates a missing file unless explicitly false.
    --- False refuses a missing named file; read-only opens never create.
    create?: boolean
    --- Opens read-only a database that nothing will change while it is
    --- open: see [`Sqlite.open`]. Giving it with `writable` raises.
    immutable?: boolean
    --- False turns SQLite's defensive mode off, for a caller that writes
    --- the schema itself, as `PRAGMA schema_version = N` does: see
    --- [`Sqlite.open`]. Every other handle keeps it.
    defensive?: boolean
    --- Holds the handle to queries as it opens: see [`Handle.reads_only`].
    --- Giving it with `writable` raises.
    reads_only?: boolean
    --- How long a call waits at another connection's lock, in
    --- nanoseconds: see [`Handle.busy_timeout`]. A minute when nil.
    wait?: integer
    --- Switches the database to write-ahead mode as it opens: see
    --- [`Handle.wal`]. Giving it without `writable` raises.
    wal?: boolean
    --- Sets `PRAGMA synchronous` as it opens: see [`Sqlite.Synchronous`].
    --- "normal" is the usual choice with `wal`.
    synchronous?: Synchronous
    --- The tables the database holds: see [`Sqlite.schema`]. A new file
    --- opened `writable` gets them; any other open fails when the file
    --- does not hold them, column for column.
    schema?: Schema
  end

  --- How [`Sqlite.memory`] makes a database.
  record MemoryOptions
    --- The tables the database starts with: see [`Sqlite.schema`].
    schema?: Schema
  end

  --- A database's tables, as the DDL that creates them: see
  --- [`Sqlite.schema`].
  type Schema = Schema

  --- One result row: see [`Handle.rows`].
  type Row = Row

  --- Every row of a result, in the order the query gave them.
  type Rows = {Row}

  --- A query's rows read one at a time: see [`Handle.query`].
  type Query = Query

  --- The version of SQLite the core carries.
  version: string

  --- A parameter value that binds SQL NULL, where a list cannot hold
  --- `nil`: `db:run("INSERT INTO t VALUES (?1, ?2)", { 1, Sqlite.NULL })`.
  --- It is read-only; a write to it raises.
  NULL: Value

  --- Internal: the connection a handle holds, as the core opens it. No
  --- caller outside cosmic's own tree holds one.
  type Connection = raw_sqlite.Handle
end

--- Opens the database file at `path`: read-only unless `opts.writable`
--- is true, in which case a missing file is created unless `opts.create`
--- is false. Returns the handle, or `nil` and why, with SQLite's codes
--- ([`Failure`]'s `code` and `extended_code`): [`Sqlite.NOTADB`] for a
--- file that is no database. `opts` that is not a table raises.
--- SQLite's special empty and `:memory:` paths still open temporary
--- databases, including with `create = false`.
---
--- `opts.immutable` opens a database that nothing will change while it
--- is open, read-only and with no lock: no `-wal`, `-shm` or journal file
--- is made beside it, and a running statement holds nothing a writer
--- waits on. A `-wal` is never read, so commits still in one do not
--- show: open a database that is being written without `immutable`.
--- Giving `immutable` with `writable` raises.
---
--- A call waits up to a minute at another connection's lock, and a signal
--- the innermost guard catches stops the wait: `opts.wait` sets another
--- wait, in nanoseconds ([`Handle.busy_timeout`]). `opts.wal` switches a
--- writable database to write-ahead mode ([`Handle.wal`]), and
--- `opts.synchronous` sets how hard a commit is kept through a power
--- loss: a file that readers share beside one writer opens as
---
---     Sqlite.open(path, { writable = true, wal = true, synchronous = "normal" })
---
--- Every handle is in SQLite's defensive mode, so no SQL it runs can
--- corrupt the file on purpose: a write to `sqlite_schema` or to the shadow tables
--- of an FTS5 or R*Tree table fails, even after `PRAGMA writable_schema
--- = ON`, and `PRAGMA schema_version = N` and `PRAGMA journal_mode = OFF`
--- run but change nothing (`MEMORY` keeps the journal off the disk
--- instead, for a file that is thrown away if the process stops while
--- writing it). Each cell is checked against its page as it is read
--- (`PRAGMA cell_size_check`, on in every connection the core opens), so a damaged or crafted file fails with
--- [`Sqlite.CORRUPT`] rather than being read past its end.
--- `opts.defensive = false` turns defensive mode off, for code that
--- writes the schema itself.
---
--- Every handle adds these SQL functions, each returning NULL for a NULL
--- argument:
---
--- - `sha256(X)`: the 32-byte digest of a text or blob.
--- - `digest(A, X)`: the digest of X under the algorithm A names (a
---   [`cosmic.hash`] `Algorithm`).
--- - `hmac(A, K, X)`: the HMAC of X under the key K over A.
--- - `deflate(X)`: the raw deflate of X, as `Compress.encode("raw", X)`
---   writes it; `inflate(X)` decodes such a stream, to a blob.
--- - `chunk(X)`: a module's bytecode as `string.dump` wrote it, where X
---   is how a database stores it ([`cosmic.store`]): as it is, or
---   raw-deflated by an older build.
---
--- `handle:limit(name, value)` sets one of the connection's limits and
--- returns the old one. A handle may attach 10 databases
--- (`ATTACH DATABASE`) until `handle:limit("attached", n)` sets more,
--- at most 125; the refusal of one too many says so.
function Sqlite.open(path: string, opts?: Sqlite.OpenOptions): (Sqlite.Handle) | (nil, Failure)
  local writable, immutable, create = opts and opts.writable, opts and opts.immutable, opts and opts.create
  local held = opts ~= nil and opts.reads_only == true
  if held and writable == true then
    error("sqlite: a database cannot be both writable and reads_only", 2)
  end
  local wait, wal, synchronous = opts and opts.wait, opts ~= nil and opts.wal == true, opts and opts.synchronous
  if wal and writable ~= true then
    error("sqlite: only a writable database is switched to wal", 2)
  end
  if wait ~= nil and (math.type(wait) ~= "integer" or wait < 0) then
    error("sqlite: wait is a nonnegative number of nanoseconds", 2)
  end
  local syncs: string? = if synchronous ~= nil then SYNCHRONOUS[synchronous] else nil end
  if synchronous ~= nil and syncs == nil then
    error("sqlite: synchronous is \"off\", \"normal\", \"full\" or \"extra\"", 2)
  end
  local defensive = not (opts ~= nil and opts.defensive == false)
  -- `open_result` raises for a path it refuses before SQLite reads it (a
  -- NUL), where `open` returns nil and why; any other raise `open`
  -- raises again.
  local called, opened = pcall(sqlite.open_result, path, writable, immutable, create, defensive)
  if not called then
    local handle, why = sqlite.open(path, writable, immutable, create, defensive)
    if handle ~= nil then
      local _, _ = handle:close()
      error(opened, 0)
    end
    return nil, Failure.coded("sqlite: " .. why, MISUSE)
  end
  if opened.code ~= OK then return nil, failed(opened) end
  local handle = handle_of(opened.handle)
  local function refused(why: Failure): nil, Failure
    local _, _ = handle:close()
    return nil, why
  end
  if wait ~= nil then handle:busy_timeout(wait) end
  if wal then
    local switched, why = handle:wal()
    if not switched then return refused(why) end
  end
  if syncs ~= nil then
    local set, why = handle:exec("PRAGMA main.synchronous = " .. syncs)
    if not set then return refused(why) end
  end
  local schema = opts and opts.schema
  if schema ~= nil then
    local holds, why = hold_schema(handle, path, schema, writable == true)
    if not holds then return refused(why) end
  end
  if held then
    local holding, why = handle:reads_only()
    if not holding then return refused(why) end
  end
  return handle
end

--- A schema: the tables a database holds, as the DDL that creates
--- them. A program declares one with `local schema`, which names a
--- type and a value, and gives the value to [`Sqlite.open`] or
--- [`Sqlite.memory`] as `schema`:
---
---     local schema Notes [[
---       CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL);
---       CREATE INDEX notes_body ON notes (body);
---     ]]
---     local db = assert(Sqlite.open("notes.db", { writable = true, schema = Notes }))
---
--- The DDL may be written `local schema Notes = A .. B`, which joins
--- string literals, `<const>` locals of the same block, and the `ddl`
--- of another schema (`Other.ddl`, `module.Other.ddl`).
--- The value is a [`Schema`] of the DDL, which the checker has read:
--- a load of the module runs no database, and the first open or
--- [`Sqlite.hold`] of it reads its tables. The type, `Notes`, is a
--- class of the handles that hold its tables: `open` and `memory`
--- give a `Notes` for `{ schema = Notes }`, as [`Sqlite.hold`] does for
--- a handle opened without it, and a `Notes` is a
--- [`Handle`] wherever one is wanted, but a handle is no `Notes`. A
--- module exports the schema with `type Notes = Notes` in its record,
--- whose table then holds the value too: another module opens a
--- handle of it with `{ schema = Store.Notes }`. A field typed
--- [`Schema`] holds a schema of no known tables, which opens a plain
--- handle.
---
--- A writable open of a new file (one with no table, index, view or
--- trigger) runs the DDL on it, in one transaction. Every open then
--- checks that the file holds each table the DDL creates, with the
--- same columns in the same order, each of the same name and declared
--- type (in capitals or not), NOT NULL and primary key place, and fails
--- naming what differs: an old file fails at open, not at a read deep
--- inside. Tables the DDL does not create, indexes, views, triggers,
--- `STRICT` and `WITHOUT ROWID` are not checked; a virtual table's own
--- tables are, as SQLite makes them. The schema is the database's final
--- state: to bring an old file to it, open the file without the schema
--- and [`Handle.migrate`] it.
---
--- The first open or [`Sqlite.hold`] of a schema runs its DDL once in
--- a memory database, to read the tables, and raises when SQLite
--- refuses it or it creates no table, as [`Sqlite.schema`] does at once.
--- So the DDL creates and does nothing else: an `ATTACH` in it fails
--- there, and a `BEGIN` fails at the open that runs it on a file. The
--- checker runs the DDL too, and reads the SQL a program sends to a
--- handle of the schema's type against it, wherever the handle goes (a
--- local, a parameter, a field): a table or column it does not create,
--- or a values list of another length than the SQL binds, is refused
--- where it is written. So is a read of a row from that SQL past its
--- last column, or one that raises on every cell its column may hold:
--- in a `STRICT` table, any read but that of the declared type
--- (`row:text(1)` of an `INTEGER` column); in another, which keeps a
--- text it cannot convert in any column, `integer` and `number` of a
--- text column and `integer` of a `REAL` one. A compound select
--- (`UNION`) and an expression are not read. SQL is read where it is
--- a literal or joins literals, until a handle of the schema is sent
--- SQL that may make a table or attach a database, or is migrated: the
--- rest of the module reads that schema's SQL no more. SQL sent in
--- another module is not seen. A row is read where it is a
--- local given `db:one`, an element of a local given `db:rows`, the
--- variable of `for _, row in ipairs(rows)`, or the parameter of the
--- function `db:map` takes.
function Sqlite.schema(ddl: string): Sqlite.Schema
  if ddl:find("\0", 1, true) ~= nil then error("sqlite: a schema's DDL cannot hold a NUL", 2) end
  local schema: Sqlite.Schema = { ddl = ddl }
  local read, why = pcall(declared, schema)
  if not read then error(why, 2) end
  return schema
end

--- `db` as a handle of `schema`, once its database holds the tables.
--- This is what [`Sqlite.open`] does for `{ schema = S }`, for a handle
--- opened first. On a writable handle of a database with no schema
--- object, it runs the DDL in one transaction. So a program can set a
--- pragma that must come before the first table, then hold the schema:
--- SQLite fixes `page_size`, `auto_vacuum` and `encoding` of a new file
--- once a transaction writes it. Then each table the DDL creates must
--- be in the database as `open` checks it, or this fails naming what
--- differs. A read-only handle, and one held to queries
--- ([`Handle.reads_only`]), only check. The checker reads the answer as
--- a handle of `schema`'s type where `schema` is a `local schema`. It
--- is `db` itself, so closing either closes both.
---
---     local db = assert(Sqlite.open(path, { writable = true }))
---     assert(db:exec("PRAGMA page_size = 4096"))
---     local notes = assert(Sqlite.hold(db, Notes))
function Sqlite.hold(db: Sqlite.Handle, schema: Sqlite.Schema): (Sqlite.Handle) | (nil, Failure)
  local holds, why = hold_schema(db, "the database", schema, not db.connection:read_only())
  if not holds then return nil, why end
  return db
end

--- `bytes` as a parameter value that binds as a blob: a plain string
--- binds as text, which compares unequal to the same bytes as a blob.
---
---     db:run("INSERT INTO files VALUES (?1, ?2)", { name, Sqlite.blob(data) })
function Sqlite.blob(bytes: string): Sqlite.Value
  return { blob = bytes }
end

--- `name` quoted as an SQL identifier, for a table or column name that
--- comes from data: in double quotes, each `"` in it doubled, so any
--- name is read as that one name and never as SQL. A name that holds a
--- NUL raises: SQLite ends the statement's text there.
---
---     db:exec("CREATE TABLE " .. Sqlite.identifier('my "notes"') .. " (body)")
function Sqlite.identifier(name: string): string
  if name:find("\0", 1, true) ~= nil then error("sqlite: an identifier cannot hold a NUL", 2) end
  return '"' .. name:gsub('"', '""') .. '"'
end

--- `text` quoted as an SQL string literal, each `'` in it doubled, for a
--- statement that cannot take a `?` parameter: a column's `DEFAULT`, a
--- view, a virtual table's arguments. Where SQL takes a parameter, bind
--- the value instead ([`Handle.run`]):
---
---     db:run("SELECT body FROM notes WHERE title = ?1", { title })
---
--- Text that holds a NUL raises.
function Sqlite.literal(text: string): string
  if text:find("\0", 1, true) ~= nil then error("sqlite: a literal cannot hold a NUL", 2) end
  return "'" .. text:gsub("'", "''") .. "'"
end

--- Disowns every connection this process has open: for a process that is a
--- copy of another, forked from it, to call before anything else.
--- SQLite has a connection used by the process that opened it alone: a
--- copy holds none of its locks, and shares its descriptors. So a copy that
--- reads a database opens it again. Every handle and statement opened
--- before raises on any use after, saying so, and its close acts as if it
--- closed, and closes nothing (a handle's returns true); one opened after
--- is the process's own. The connections of the program's store are not
--- disowned: the runtime reads its modules through them, in a copy as in
--- the process.
function Sqlite.disown()
  sqlite.disown()
end

--- A writable database held in memory: it is gone when the handle
--- closes. With `schema` it starts with that schema's tables
--- ([`Sqlite.schema`]).
function Sqlite.memory(opts?: Sqlite.MemoryOptions): (Sqlite.Handle) | (nil, Failure)
  return Sqlite.open(":memory:", { writable = true, schema = opts and opts.schema })
end
--- Internal: the handle of a connection the runtime opened, for
--- [`cosmic.store`] and for tests of the connection itself. No other
--- caller uses it.
function Sqlite.borrowed(connection: Sqlite.Connection): Handle
  return handle_of(connection)
end

Sqlite.OK = OK
Sqlite.LOCKED = 6
Sqlite.INTERRUPT = 9
Sqlite.CORRUPT = 11
Sqlite.NOTADB = 26
Sqlite.ERROR = ERROR
Sqlite.BUSY = BUSY
Sqlite.MISUSE = MISUSE
Sqlite.RANGE = RANGE
Sqlite.AUTH = 23
Sqlite.version = sqlite.version
Sqlite.NULL = sqlite.NULL

return Sqlite
