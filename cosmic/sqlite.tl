--- SQLite, typed: cosmic's embedded SQL database, a `db` in one file or in
--- memory, with no server and nothing to install.
---
--- Values keep their type: text and bytes are different, and a parameter
--- is bound by naming what it is. A handle's methods give the shapes a
--- caller wants: a query that yields rows, all at once (`db:rows`) or
--- one at a time (`db:query`), a statement run once (`db:run`), and a
--- transaction that rolls back when the work inside it fails
--- (`db:transact`); each answers a [`Failure`] when SQLite refuses.
---
--- A parameter is a one-field table naming its type, one per `?N`, in
--- order; a result row is read a column at a time by the type the caller
--- expects, from 1:
---
---     local db = assert(Sqlite.open("notes.db", { writable = true }))
---     assert(db:exec("CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, body TEXT)"))
---     assert(db:run("INSERT INTO t (body) VALUES (?1)", { { text = "hi" } }))
---     local rows = assert(db:rows("SELECT id, body FROM t WHERE id = ?1",
---       { { integer = db:last_insert_rowid() } }))
---     print(rows[1]:integer(1), rows[1]:text(2)) -- 1  hi
---
--- `{ integer = n }`, `{ number = x }`, `{ text = s }` and `{ blob = b }`
--- bind those types; `{}` binds NULL. A [`Sqlite.Row`] is not a list:
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
--- sections "copying tables between files" and "a prepared statement in
--- a loop". `cosmic sql` cannot attach.
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
--- column at, so a query that does not answer what the reader assumed
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
--- `rows` and [`Handle.query`] answer rows that keep each column's
--- SQLite type; [`Handle.text_rows`] answers rows whose every column is
--- text.
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
  --- float (one beyond 2^53 rounds). A REAL cell is answered as stored,
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
  --- Every column as `text` answers it, in order, as a new list: for a
  --- row from [`Handle.text_rows`], its columns. A column of another type
  --- raises.
  texts: function(Row): {string}
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
  texts: function(Stored): {string}
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
--- its bytes, as [`Handle.text_rows`] answers it.
local function texts_of(statement: raw_sqlite.Statement): Row
  return cells_of(statement, true)
end

--- The failure SQLite answered `outcome` with, its codes kept.
local function failed(outcome: raw_sqlite.Outcome): Failure
  local reason = if outcome.reason ~= "" then outcome.reason else "sqlite: the call failed" end
  local kind: Failure.Kind = if outcome.timed_out == true then "timeout" elseif outcome.cancelled == true then
    "cancelled" else "library" end
  return Failure.coded(reason, outcome.code, outcome.extended_code, kind)
end

--- Steps `statement` once and gives `project` the row it stands on: the
--- projection, or `nil` and nil when the statement is done, or `nil` and
--- why when the step failed. [`Handle.rows`], [`Handle.text_rows`],
--- [`Handle.map`] and [`Handle.query`] all step through it, so they agree
--- on what a failure says.
local function step_row<T>(statement: raw_sqlite.Statement,
                           project: function(raw_sqlite.Statement): T): T?, Failure?
  local state = statement:step_result()
  if state is raw_sqlite.ExecResult then return nil, failed(state) end
  if state == "done" then return nil, nil end
  return project(statement), nil
end

-- How an object of this module is made: see the note on objects in
-- cosmic/stream.tl.

--- SQLite's result codes this module answers of its own: a library
--- routine used against its contract, and a parameter at no position the
--- statement has.
local MISUSE <const> = 21
local RANGE <const> = 25
local OK <const> = 0
local ERROR <const> = 1
local BUSY <const> = 5

--- Finalizes `query`'s statement, once.
local function finish(query: Query)
  if query.open then
    query.open = false
    query.statement:finalize()
  end
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
  --- Internal: whether the last row has been read. No caller reads or
  --- writes it.
  mut ended: boolean
  --- Internal: why stepping failed, nil until it does. No caller reads or
  --- writes it; [`Query.failure`] answers it.
  mut failed?: Failure

  --- The next row; nil and nil after the last; nil and why when
  --- stepping failed, the same again on every later read.
  function read(self): Row?, Failure?
    local earlier = self.failed
    if earlier ~= nil then return nil, earlier end
    if self.ended then return nil, nil end
    if not self.open then return nil, Failure.coded("sqlite: the query is closed", MISUSE) end
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
  --- or a `close` inside the loop, ends it early with no failure.
  function failure(self): Failure?
    return self.failed
  end

  --- Finalizes the statement, so the handle can close; the last
  --- row, a failure and a `<close>` variable each do it too. A read
  --- afterward fails. Closing again does nothing.
  function close(self)
    finish(self)
  end

  function __close(self)
    self:close()
  end
end

--- Raises, blaming as [`checked`] does, when a text of `texts` holds a NUL,
--- which carray reads to its first NUL.
local function check_texts(key: integer, texts: {string})
  for i, text in ipairs(texts) do
    if text:find("\0", 1, true) ~= nil then
      error("sqlite: element " .. tostring(i) .. " of parameter " .. tostring(key) .. "'s texts holds a NUL; bind it in blobs", 5)
    end
  end
end

--- Raises, blaming the caller of the public function that calls the
--- function that calls this, when a Value of `values` holds more than one
--- of its fields or a text of its `texts` holds a NUL. It runs before a
--- statement is prepared, so a raise leaves none to finalize. Answers the
--- highest position, 0 for none.
local function checked(values: {raw_sqlite.Value}): integer
  for key, value in ipairs(values) do
    local texts = value.texts
    if texts ~= nil then check_texts(key, texts) end
    -- Counted field by field, with no table made: this runs for every value of every statement bound.
    local fields = (if value.integer ~= nil then 1 else 0 end) + (if value.number ~= nil then 1 else 0 end) +
      (if value.text ~= nil then 1 else 0 end) + (if value.blob ~= nil then 1 else 0 end) +
      (if value.integers ~= nil then 1 else 0 end) + (if value.numbers ~= nil then 1 else 0 end) +
      (if texts ~= nil then 1 else 0 end) + (if value.blobs ~= nil then 1 else 0 end)
    if fields > 1 then
      error("sqlite: parameter " .. tostring(key) .. " has more than one Value field", 4)
    end
  end
  return #values
end

--- Binds SQLite parameters positionally, which [`checked`] has found
--- well formed, `highest` the greatest position they hold: the positions
--- must be 1..N, matching the statement's own placeholders, or the
--- statement is refused with why: [`Sqlite.RANGE`] for a position, and
--- [`Sqlite.ERROR`] for a value SQLite would not bind. Nil where every
--- value is bound.
local function bind(statement: raw_sqlite.Statement, values: {raw_sqlite.Value}, highest: integer): Failure?
  local count = statement:parameters()
  if highest > count then
    return Failure.coded("sqlite: values holds a parameter " .. tostring(highest) ..
        ", and the statement has " .. tostring(count), RANGE)
  end
  for index = 1, count do
    local value = values[index]
    if value == nil then
      return Failure.coded("sqlite: parameter " .. tostring(index) .. " has no value (use {} for NULL)", RANGE)
    end
    local ok: boolean
    local trouble: string
    local integer, number, text, blob = value.integer, value.number, value.text, value.blob
    local integers, numbers, texts, blobs = value.integers, value.numbers, value.texts, value.blobs
    if integer ~= nil then
      ok, trouble = statement:bind_integer(index, integer)
    elseif number ~= nil then
      ok, trouble = statement:bind_number(index, number)
    elseif text ~= nil then
      ok, trouble = statement:bind_text(index, text)
    elseif blob ~= nil then
      ok, trouble = statement:bind_blob(index, blob)
    elseif integers ~= nil then
      ok, trouble = statement:bind_integers(index, integers)
    elseif numbers ~= nil then
      ok, trouble = statement:bind_numbers(index, numbers)
    elseif texts ~= nil then
      ok, trouble = statement:bind_texts(index, texts)
    elseif blobs ~= nil then
      ok, trouble = statement:bind_blobs(index, blobs)
    else
      ok, trouble = statement:bind_null(index)
    end
    if not ok then
      return Failure.coded("sqlite: parameter " .. tostring(index) .. ": " .. trouble, ERROR)
    end
  end
  return nil
end

--- `sql` prepared on `handle` with `values` bound, or nil and why; a
--- statement that does not bind is released. A kept statement whose table
--- has gone fails with "no such table" at its step, after its binding, and
--- not at its prepare.
local function prepared(handle: raw_sqlite.Handle, sql: string,
                        given?: {raw_sqlite.Value}, unbound?: boolean,
                        cached?: boolean): (raw_sqlite.Statement) | (nil, Failure)
  local values = given or {}
  local highest = checked(values)
  -- The core's `prepare_result` raises for SQL it refuses before SQLite
  -- reads it (a NUL, no statement, more than one), where `prepare`
  -- answers why; any other raise (a closed handle) `prepare` raises again.
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
  if opened.code ~= OK then return nil, failed(opened) end
  local statement = opened.statement
  if unbound == true then return statement end
  local why = bind(statement, values, highest)
  if why ~= nil then
    statement:release()
    return nil, why
  end
  return statement
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

--- An open database, as [`Sqlite.open`] and [`Sqlite.memory`] answer it.
--- Every method that can fail answers `nil` or `false` and a [`Failure`]
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
  --- changed the database when a later one fails. SQL holding a NUL
  --- answers false and why ([`Sqlite.MISUSE`]).
  function exec(self, sql: string): (true) | (false, Failure)
    if sql:find("\0", 1, true) ~= nil then
      return false, Failure.coded("sqlite: the SQL holds a NUL", MISUSE)
    end
    local outcome = self.connection:exec_result(sql)
    if outcome.code ~= OK then return false, failed(outcome) end
    return true
  end

  --- Runs a statement that yields no rows: it answers `true`, or
  --- `false` and why.
  ---
  --- `values` is a dense list indexed by SQLite's parameter index,
  --- through its highest index. Repeated named parameters share an
  --- index, and a gap in `?NNN` numbers still needs an entry (use `{}`).
  --- A missing entry or an extra key answers `false` and why
  --- ([`Sqlite.RANGE`]). A malformed [`Sqlite.Value`] (no table, a field
  --- it has no name for, more than one field) raises, as does a key that
  --- is no position from 1.
  function run(self, sql: string, values?: {raw_sqlite.Value}): (true) | (false, Failure)
    local statement, trouble = prepared(self.connection, sql, values, false, true)
    if statement == nil then return false, trouble end
    local state = statement:step_result()
    statement:release()
    if state is raw_sqlite.ExecResult then return false, failed(state) end
    return true
  end

  --- Every row a query yields, each a [`Sqlite.Row`] that keeps its
  --- columns' SQLite types. Answers the rows, or `nil` and why. `values`
  --- follows [`Handle.run`]'s contract.
  function rows(self, sql: string, values?: {raw_sqlite.Value}): ({Row}) | (nil, Failure)
    local statement, trouble = prepared(self.connection, sql, values, false, true)
    if statement == nil then return nil, trouble end
    return each_row(statement, cells_of)
  end

  --- Every row a query yields as `project` makes it: the list of what
  --- `project` answered for each row in turn, or `nil` and why.
  --- `project` reads the row's columns (`r:text(1)`) and answers one
  --- value, never nil, which is how a caller builds a record per row. A
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
  ---       { { integer = 0 } }, function(r: Sqlite.Row): Named
  ---         return { name = r:text(1), n = r:integer(2) }
  ---       end))
  ---     print(#found, found[2].name) -- 2  b
  function map<T>(self, sql: string, values: {raw_sqlite.Value}?,
                  project: function(Row): T): ({T}) | (nil, Failure)
    local statement, trouble = prepared(self.connection, sql, values, false, true)
    if statement == nil then return nil, trouble end
    local out: mut {T} = {}
    while true do
      local state = statement:step_result()
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
  function query(self, sql: string, values?: {raw_sqlite.Value}): (Query) | (nil, Failure)
    local opened, trouble = prepared(self.connection, sql, values)
    if opened == nil then return nil, trouble end
    local q: Query = { statement = opened, open = true, ended = false, failed = nil }
    return q
  end

  --- A direct text projection for callers whose SQL already defines the
  --- coercion they want. Every column of every row is text, read with
  --- `row:text(i)`: SQLite's byte representation is returned for every
  --- value: NULL, empty text and empty blob all become `""`; integers
  --- and floats use SQLite's text formatting; text and blobs remain byte
  --- strings, including NUL. Such a row answers `kind` as `"text"` for
  --- every column and [`Row.is_null`] as false, and raises from `integer`,
  --- `number` and `blob`: read those from [`Handle.rows`].
  function text_rows(self, sql: string, values?: {raw_sqlite.Value}): ({Row}) | (nil, Failure)
    local statement, trouble = prepared(self.connection, sql, values, false, true)
    if statement == nil then return nil, trouble end
    return each_row(statement, texts_of)
  end

  --- Runs `work` inside a transaction and commits when it answers
  --- `true`. When `work` answers `false` and a [`Failure`], or the
  --- commit fails, the transaction rolls back and this answers `false`
  --- and that failure (one that says the work gave no why, where it gave
  --- none). When `work` raises, the transaction rolls back and the same
  --- error is raised again. A transaction already open on the handle
  --- makes `BEGIN` fail, so calls do not nest.
  ---
  --- `DETACH` of an attached database fails with "database X is locked"
  --- while a transaction that read that database is open. `ATTACH` it,
  --- `transact`, and `DETACH` once the transaction has committed.
  ---
  ---     local ok, why = db:transact(function(): (true) | (false, Failure)
  ---       local a, trouble = db:run("INSERT INTO t (body) VALUES (?1)", { { text = "a" } })
  ---       if not a then return false, trouble end
  ---       return db:run("INSERT INTO t (body) VALUES (?1)", { { text = "b" } })
  ---     end)
  function transact(self, work: function(): (true) | (false, Failure)): (true) | (false, Failure)
    local connection = self.connection
    local started = connection:exec_result("BEGIN")
    if started.code ~= OK then return false, failed(started) end
    local called, ok, why = pcall(function(): boolean, Failure?
      local done, trouble = work()
      return done, trouble
    end)
    if not called then
      local _ = connection:exec_result("ROLLBACK")
      error(ok, 0)
    end
    if not ok then
      local _ = connection:exec_result("ROLLBACK")
      return false, why or Failure.new("sqlite: transact: the work failed and said no why")
    end
    local committed = connection:exec_result("COMMIT")
    if committed.code ~= OK then
      local _ = connection:exec_result("ROLLBACK")
      return false, failed(committed)
    end
    return true
  end

  --- `sql`, which must hold exactly one statement, compiled for a caller
  --- that steps it, rebinds it and runs it again: a
  --- [`Sqlite.Statement`], or nil and why. Given `values`, they are bound
  --- as [`Handle.run`]'s contract says; without them nothing is, and
  --- the statement's own `bind_*` methods bind each parameter (an
  --- unbound one is NULL). Finalize the statement when done; the handle
  --- cannot close while one is open.
  ---
  ---     local insert = assert(db:prepare("INSERT INTO t (owner, n) VALUES (?1, ?2)",
  ---       { { text = "me" }, { integer = 0 } }))
  ---     for n = 1, 3 do
  ---       assert(insert:bind_integer(2, n))
  ---       assert(insert:step() == "done")
  ---       assert(insert:rewind())
  ---     end
  ---     insert:finalize()
  function prepare(self, sql: string, values?: {raw_sqlite.Value}): (raw_sqlite.Statement) | (nil, Failure)
    return prepared(self.connection, sql, values, values == nil)
  end

  --- Waits up to `timeout_ns` at locks, rounded up to milliseconds,
  --- checking the innermost guard's unread signal without taking it: a
  --- signal stops the wait, and the call returns a failure of kind
  --- "cancelled" with SQLite's code, usually [`Sqlite.BUSY`] (no
  --- rollback is implied). Each call shares one budget across its
  --- locking events, starting at the first contention. Zero never
  --- sleeps. A negative or noninteger duration raises, as does a
  --- borrowed handle. Without a guard, only the time limits it.
  --- `PRAGMA busy_timeout` reads zero for this handler; writing that
  --- pragma replaces it, and calling this again reinstalls it. SQLite
  --- can refuse a lock without calling any busy handler.
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
  --- SQLite answers it, while a statement or query is still open.
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
  --- `"worker_threads"`), and answers the value it had. A negative
  --- `value` changes nothing, so it reads the limit. A value above the
  --- library's own ceiling raises, naming the ceiling, as does an
  --- unknown name. `"attached"` starts at 10 and may be raised to 125.
  function limit(self, name: string, value: integer): integer
    return self.connection:limit(name, value)
  end

  -- TODO: once ci/cosmic-driver.pin names a release with the handle's
  -- methods, move build/zig.tl's lock to `exec` and delete this and
  -- [`Sqlite.ExecResult`].

  --- Runs `sql` as [`Handle.exec`] does and answers SQLite's outcome as
  --- a record: for a script that also runs on a release older than
  --- [`Handle.exec`]'s failure. Write new code with [`Handle.exec`].
  function exec_result(self, sql: string): raw_sqlite.ExecResult
    return self.connection:exec_result(sql)
  end

  function __close(self)
    local _, _ = self:close()
  end
end

--- A handle that holds `connection`.
local function handle_of(connection: raw_sqlite.Handle): Handle
  return { connection = connection }
end

local record Sqlite
  --- An open database, as `open` and `memory` return it, with the
  --- methods that query it: `cosmic docs Sqlite.Handle` lists them.
  type Handle = Handle
  --- One prepared statement, as [`Handle.prepare`] answers it.
  type Statement = raw_sqlite.Statement
  --- What [`Handle.exec_result`] answers.
  type ExecResult = raw_sqlite.ExecResult

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

  --- One bound parameter. Its field says what SQLite is told it is, so
  --- a blob never arrives as text by accident. At most one field is
  --- allowed; an empty table explicitly binds SQL NULL. A value of
  --- another shape raises where it is bound. A list in `integers`,
  --- `numbers`, `texts` or `blobs` is bound as an array that only
  --- `carray(?N)` reads, as a table of its elements: `x IN carray(?1)`
  --- tests membership in it. Used as a value, compared, stored or
  --- returned, it is NULL.
  type Value = raw_sqlite.Value

  --- The SQLite storage class of a result cell: see [`Sqlite.Row.kind`].
  type Kind = Kind

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
  end

  --- One result row: see [`Handle.rows`].
  type Row = Row

  --- Every row of a result, in the order the query gave them.
  type Rows = {Row}

  --- A query's rows read one at a time: see [`Handle.query`].
  type Query = Query

  --- The version of SQLite the core carries.
  version: string

  --- Internal: the connection a handle holds, as the core opens it. No
  --- caller outside cosmic's own tree holds one.
  type Connection = raw_sqlite.Handle
end

--- Opens the database file at `path`: read-only unless `opts.writable`
--- is true, in which case a missing file is created unless `opts.create`
--- is false. Answers the handle, or `nil` and why, with SQLite's codes
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
--- Every handle adds these SQL functions, each answering NULL for a NULL
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
--- answers the old one. A handle may attach 10 databases
--- (`ATTACH DATABASE`) until `handle:limit("attached", n)` raises that,
--- to at most 125; the refusal of one too many says so.
function Sqlite.open(path: string, opts?: Sqlite.OpenOptions): (Sqlite.Handle) | (nil, Failure)
  local writable, immutable, create = opts and opts.writable, opts and opts.immutable, opts and opts.create
  local held = opts ~= nil and opts.reads_only == true
  if held and writable == true then
    error("sqlite: a database cannot be both writable and reads_only", 2)
  end
  local defensive = not (opts ~= nil and opts.defensive == false)
  -- `open_result` raises for a path it refuses before SQLite reads it (a
  -- NUL), where `open` answers why; any other raise `open` raises again.
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
  if held then
    local holding, why = handle:reads_only()
    if not holding then
      local _, _ = handle:close()
      return nil, why
    end
  end
  return handle
end

--- Disowns every connection this process has open: for a process that is a
--- copy of another, forked from it, to call before anything else.
--- SQLite has a connection used by the process that opened it alone: a
--- copy holds none of its locks, and shares its descriptors. So a copy that
--- reads a database opens it again. Every handle and statement opened
--- before raises on any use after, saying so, and its close answers as one
--- that closed while closing nothing; one opened after is the process's
--- own. The connections of the program's store are not disowned: the
--- runtime reads its modules through them, in a copy as in the process.
function Sqlite.disown()
  sqlite.disown()
end

--- A writable database held in memory: it is gone when the handle
--- closes.
function Sqlite.memory(): (Sqlite.Handle) | (nil, Failure)
  return Sqlite.open(":memory:", { writable = true })
end
--- Internal: the handle of a connection the runtime opened, for
--- [`cosmic.store`] and for tests of the connection itself. No other
--- caller uses it.
function Sqlite.borrowed(connection: Sqlite.Connection): Handle
  return handle_of(connection)
end

-- TODO: once ci/cosmic-driver.pin names a release with the handle's
-- methods, move the callers in ci/, build/perf.tl and
-- eval/check/grade.tl to them and delete these six, which those files
-- call on the pinned release.

--- [`Handle.run`] of `handle`, for ci/.
function Sqlite.run(handle: Handle, sql: string, values?: {raw_sqlite.Value}): (true) | (false, Failure)
  return handle:run(sql, values)
end

--- [`Handle.rows`] of `handle`, for ci/.
function Sqlite.rows(handle: Handle, sql: string, values?: {raw_sqlite.Value}): ({Row}) | (nil, Failure)
  return handle:rows(sql, values)
end

--- [`Handle.map`] of `handle`, for ci/.
function Sqlite.map<T>(handle: Handle, sql: string, values: {raw_sqlite.Value}?,
                       project: function(Row): T): ({T}) | (nil, Failure)
  return handle:map(sql, values, project)
end

--- [`Handle.query`] of `handle`, for ci/.
function Sqlite.query(handle: Handle, sql: string, values?: {raw_sqlite.Value}): (Query) | (nil, Failure)
  return handle:query(sql, values)
end

--- [`Handle.text_rows`] of `handle`, for ci/ and the files the pinned
--- release runs.
function Sqlite.text_rows(handle: Handle, sql: string, values?: {raw_sqlite.Value}): ({Row}) | (nil, Failure)
  return handle:text_rows(sql, values)
end

--- [`Handle.transact`] of `handle`, for ci/.
function Sqlite.transact(handle: Handle,
                         work: function(): (true) | (false, Failure)): (true) | (false, Failure)
  return handle:transact(work)
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

return Sqlite
