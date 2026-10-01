--- SQLite, typed.
---
--- Values keep their type: text and bytes are different, and a parameter
--- is bound by naming what it is. On top of a handle this module gives
--- the shapes a caller wants: a query that yields rows, all at once
--- (`rows`) or one at a time (`query`), a statement run once (`run`),
--- and a transaction that rolls back when the work inside it fails
--- (`transact`).
---
--- A parameter is a one-field table naming its type, one per `?N`, in
--- order; a result cell carries its `kind` and the matching field:
---
---     local db = assert(Sqlite.open("notes.db", { writable = true }))
---     assert(db:exec("CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, body TEXT)"))
---     assert(Sqlite.run(db, "INSERT INTO t (body) VALUES (?1)", { { text = "hi" } }))
---     local rows = assert(Sqlite.rows(db, "SELECT id, body FROM t WHERE id = ?1",
---       { { integer = db:last_insert_rowid() } }))
---     print(rows[1][1].integer, rows[1][2].text) -- 1  hi
---
--- `{ integer = n }`, `{ number = x }`, `{ text = s }` and `{ blob = b }`
--- bind those types; `{}` binds NULL.
---
--- SQLite's JSON functions read JSON5 always, and in cosmic's copy `#`
--- line comments too, as `cosmic.json` does given `hash_comments`: a
--- text in YAML's flow style reads the same through either.

-- The raw module behind this one lives under the reserved
-- `cosmic.internal.` namespace, which never satisfies an ordinary
-- `require` for any caller -- see cosmic/store.tl for why -- and
-- arrives instead as the second argument `require` passes this
-- chunk's own loader, present because this module was itself loaded,
-- trusted, from the binary's own tree. Boot mode falls back to
-- requiring it by name, which only boot's own preload answers.
local type raw_sqlite = require("cosmic.internal.sqlite")

local extra: any = select(2, ...)
local sqlite: raw_sqlite
if type(extra) == "table" then
  sqlite = extra as raw_sqlite
else
  sqlite = require("cosmic.internal.sqlite")
end

local record Sqlite
  --- An open database, as `open` and `memory` return it: the type to
  --- name for a parameter or field that holds one.
  type Handle = raw_sqlite.Handle
  --- One prepared statement.
  type Statement = raw_sqlite.Statement

  --- One bound parameter. Its field says what SQLite is told it is, so
  --- a blob never arrives as text by accident. At most one field is
  --- allowed; an empty table explicitly binds SQL NULL.
  record Value
    --- Bound as an SQLite integer.
    integer: integer
    --- Bound as a floating-point number.
    number: number
    --- Bound as text.
    text: string
    --- Bound as a blob: bytes, never text.
    blob: string
  end

  --- The SQLite storage class of a result cell: the field of a [`Cell`]
  --- that holds its value is the one of the same name, and a `"null"`
  --- cell has none.
  enum Kind
    "null"
    "integer"
    "number"
    "text"
    "blob"
  end

  --- How [`Sqlite.open`] opens a database.
  record OpenOptions
    --- Opens for reading and writing, creating the file when it is
    --- missing. Without it the database is read-only.
    writable: boolean
    --- Opens read-only a database that nothing will change while it is
    --- open: see [`Sqlite.open`]. Giving it with `writable` raises.
    immutable: boolean
  end

  --- One query result value. Exactly the field its `kind` names is
  --- present, except that a null cell has no value field.
  record Cell
    --- Which field holds the value.
    kind: Kind
    --- The value of an integer cell.
    integer: integer
    --- The value of a number cell.
    number: number
    --- The value of a text cell.
    text: string
    --- The bytes of a blob cell.
    blob: string
  end

  --- One result row: its cells in column order.
  type Row = {Cell}
  --- Every row of a result, in the order the query gave them.
  type Rows = {Row}

  --- A query's rows read one at a time: see [`Sqlite.query`].
  record Query
    metamethod __close: function(Query)
    --- The next row, and ""; nil and "" after the last; nil and why
    --- when stepping failed, the same again on every later read.
    read: function(Query): Row | nil, string
    --- An iterator for a `for` loop over the rows still to come. It
    --- ends at the last one or at a failure, which `failure` then says.
    each: function(Query): function(): Row
    --- Why the rows ended early, or "" when they have not: after an
    --- `each` loop that ran out, "" means every row was read. A `break`,
    --- or a `close` inside the loop, ends it early with no failure.
    failure: function(Query): string
    --- Finalizes the statement, so the handle can close; the last
    --- row, a failure and a `<close>` variable each do it too. A read
    --- afterward fails. Closing again does nothing.
    close: function(Query)
  end

  --- The version of SQLite the core carries.
  version: string
end

--- Opens the database file at `path`: read-only unless `opts.writable`
--- is true, in which case a missing file is created. Answers the handle,
--- or `nil` and why. `opts` that is not a table raises.
---
--- `opts.immutable` opens a database that nothing will change while it
--- is open, read-only and with no lock: no `-wal`, `-shm` or journal file
--- is made beside it, and a running statement holds nothing a writer
--- waits on. A `-wal` is never read, so commits still in one do not
--- show: open a database that is being written without `immutable`.
--- Giving `immutable` with `writable` raises.
---
--- Every handle adds these SQL functions, each answering NULL for a NULL
--- argument:
---
--- - `sha256(X)`: the 32-byte digest of a text or blob.
--- - `digest(A, X)`: the digest of X under the algorithm A names (a
---   [`cosmic.hash`] `Algorithm`).
--- - `hmac(A, K, X)`: the HMAC of X under the key K over A.
--- - `deflate(X)`: the raw deflate of X, as `Compress.deflate("raw", X)`
---   writes it; `inflate(X)` decodes such a stream, to a blob.
---
--- `handle:limit(name, value)` sets one of the connection's limits,
--- `"attached"` among them, and answers the old one.
function Sqlite.open(path: string, opts?: Sqlite.OpenOptions): Sqlite.Handle | nil, string
  local given: any = opts
  if given ~= nil and type(given) ~= "table" then
    error("sqlite: open: options is a table such as { writable = true }, not a " ..
      type(given), 2)
  end
  return sqlite.open(path, opts and opts.writable, opts and opts.immutable)
end

--- A writable database held in memory: it is gone when the handle
--- closes.
function Sqlite.memory(): Sqlite.Handle | nil, string
  return sqlite.open(":memory:", true)
end

--- Binds SQLite parameters positionally. Parameter keys must be
--- positional (1..N, matching the statement's own placeholders), and
--- each value must be a table with at most one field, named integer,
--- number, text, or blob ({} for NULL).
local function bind(
  statement: Sqlite.Statement, values: {Sqlite.Value}
): boolean, string
  local count = statement:parameters()
  for key in pairs(values as {any: any}) do
    if not (key is number) or key % 1 ~= 0 or key < 1 or key > count then
      return false, "unexpected parameter key: " .. tostring(key)
    end
  end
  for index = 1, count do
    local value = values[index]
    if type(value) ~= "table" then
      return false, "parameter " .. index .. ": expected a Value table (use {} for NULL)"
    end
    local fields = 0
    for key in pairs(value as {any: any}) do
      if key ~= "integer" and key ~= "number" and key ~= "text" and key ~= "blob" then
        return false, "parameter " .. index .. ": unknown Value field: " .. tostring(key)
      end
      fields = fields + 1
    end
    if fields > 1 then
      return false, "parameter " .. index .. ": expected at most one Value field"
    end
    local ok: boolean
    local trouble: string
    if value.integer ~= nil then
      ok, trouble = statement:bind_integer(index, value.integer)
    elseif value.number ~= nil then
      ok, trouble = statement:bind_number(index, value.number)
    elseif value.text ~= nil then
      ok, trouble = statement:bind_text(index, value.text)
    elseif value.blob ~= nil then
      ok, trouble = statement:bind_blob(index, value.blob)
    else
      ok, trouble = statement:bind_null(index)
    end
    if not ok then
      return false, "parameter " .. index .. ": " .. trouble
    end
  end
  return true, ""
end

--- `sql` prepared on `handle` with `values` bound, or nil and why; a
--- statement that does not bind is finalized.
local function prepared(handle: Sqlite.Handle, sql: string,
                        values: {Sqlite.Value}): Sqlite.Statement | nil, string
  local statement, trouble = handle:prepare(sql)
  if statement == nil then
    return nil, trouble
  end
  local bound, why = bind(statement, values or {})
  if not bound then
    statement:finalize()
    return nil, why
  end
  return statement, ""
end

--- Runs a statement that yields no rows: it answers `true` and
--- "", or `false` and why.
---
--- `values` is a dense list indexed by SQLite's parameter index, through
--- its highest index. Repeated named parameters share an index, and a
--- gap in `?NNN` numbers still needs an entry (use `{}`). A missing entry
--- or an extra key is an error.
function Sqlite.run(handle: Sqlite.Handle, sql: string,
                    values?: {Sqlite.Value}): boolean, string
  local statement, trouble = prepared(handle, sql, values)
  if statement == nil then
    return false, trouble
  end
  local state, failure = statement:step()
  statement:finalize()
  if state == nil then
    return false, failure
  end
  return true, ""
end

--- The column at `index`, from zero, of the row `statement` was just
--- stepped to, as a typed cell: SQL NULL is `kind = "null"`.
local function cell_of(statement: Sqlite.Statement, index: integer): Sqlite.Cell
  local kind = statement:kind(index)
  if kind == "integer" then
    return { kind = "integer", integer = statement:integer(index) }
  elseif kind == "number" then
    return { kind = "number", number = statement:number(index) }
  elseif kind == "text" then
    return { kind = "text", text = statement:bytes(index) }
  elseif kind == "blob" then
    return { kind = "blob", blob = statement:bytes(index) }
  end
  return { kind = "null" }
end

--- The row `statement` was just stepped to, as typed cells in column
--- order. Its columns are asked after each step: a schema change
--- re-prepares the statement, and its columns with it.
local function cells_of(statement: Sqlite.Statement): Sqlite.Row
  local row: Sqlite.Row = {}
  for index = 0, statement:columns() - 1 do
    row[index + 1] = cell_of(statement, index)
  end
  return row
end

--- The row `statement` was just stepped to, as the bytes of each column
--- in order. Asked after each step, as [`cells_of`] is.
local function texts_of(statement: Sqlite.Statement): {string}
  local row: {string} = {}
  for index = 0, statement:columns() - 1 do
    row[index + 1] = statement:bytes(index)
  end
  return row
end

--- Steps `statement` once and gives `project` the row it stands on: the
--- projection, or `nil` and "" when the statement is done, or `nil` and
--- why when the step failed. [`Sqlite.rows`], [`Sqlite.text_rows`] and
--- [`Sqlite.query`] all step through it, so they agree on what a failure
--- says.
local function step_row<T>(statement: Sqlite.Statement,
                           project: function(Sqlite.Statement): T): T | nil, string
  local state, failure = statement:step()
  if state == nil then
    return nil, failure ~= "" and failure or "sqlite: the step failed"
  end
  if state == "done" then
    return nil, ""
  end
  return project(statement), ""
end

--- Every row of `statement` as `project` gives it, and the statement
--- finalized: the rows, or `nil` and why a step failed.
local function each_row<T>(statement: Sqlite.Statement,
                           project: function(Sqlite.Statement): T): {T} | nil, string
  local out: {T} = {}
  while true do
    local row, failure = step_row(statement, project)
    if row == nil then
      statement:finalize()
      if failure ~= "" then
        return nil, failure
      end
      return out, ""
    end
    out[#out + 1] = row
  end
end

--- Every row a query yields, each a dense list of typed cells in column
--- order; SQL NULL is a cell with `kind = "null"`. Answers the rows, or
--- `nil` and why. `values` follows [`Sqlite.run`]'s contract.
function Sqlite.rows(handle: Sqlite.Handle, sql: string,
                      values?: {Sqlite.Value}): Sqlite.Rows | nil, string
  local statement, trouble = prepared(handle, sql, values)
  if statement == nil then
    return nil, trouble
  end
  return each_row(statement, cells_of)
end

local query_mt: metatable<Sqlite.Query> = {
  __close = function(self: Sqlite.Query)
    self:close()
  end,
}

--- A query whose rows are read one at a time, as `rows` gives them but
--- never all held at once: nil and why when the statement does not
--- prepare or bind (`values` follows [`Sqlite.run`]'s contract). The
--- statement stays open, and the handle cannot close, until the last
--- row is read, a step fails, or the query is
--- closed; hold it in a `<close>` variable to close it on a `break` or
--- an error too.
---
--- An open query holds SQLite's read lock on a file database between
--- reads, so a writer on another connection waits for it (in rollback
--- mode, up to the busy timeout, then fails): read it out promptly. A
--- write on the same connection to a table the query reads may be
--- read back by it, without end for an insert into a table scanned
--- whole; collect what to write first. The statement runs at the first
--- read, not before: [`Sqlite.run`] is for one that yields no rows.
---
---     local q <close> = assert(Sqlite.query(db, "SELECT id, body FROM t"))
---     for row in q:each() do print(row[1].integer, row[2].text) end
---     assert(q:failure() == "", q:failure())
function Sqlite.query(handle: Sqlite.Handle, sql: string,
                      values?: {Sqlite.Value}): Sqlite.Query | nil, string
  local opened, trouble = prepared(handle, sql, values)
  if opened == nil then
    return nil, trouble
  end
  local statement: Sqlite.Statement = opened
  local open = true
  local ended = false
  local failed = ""
  local q: Sqlite.Query = {}
  local function finish()
    if open then
      open = false
      statement:finalize()
    end
  end
  q.read = function(_self: Sqlite.Query): Sqlite.Row | nil, string
    if failed ~= "" then return nil, failed end
    if ended then return nil, "" end
    if not open then return nil, "sqlite: the query is closed" end
    local row, failure = step_row(statement, cells_of)
    if row == nil then
      if failure == "" then
        ended = true
      else
        failed = failure
      end
      finish()
      return nil, failure
    end
    return row, ""
  end
  q.each = function(self: Sqlite.Query): function(): Sqlite.Row
    return function(): Sqlite.Row
      local row, _ = self:read()
      return row
    end
  end
  q.failure = function(_self: Sqlite.Query): string
    return failed
  end
  q.close = function(_self: Sqlite.Query)
    finish()
  end
  setmetatable(q, query_mt)
  return q, ""
end

--- A direct text projection for callers whose SQL already defines the
--- coercion they want. SQLite's byte representation is returned for
--- every value: NULL, empty text and empty blob all become `""`;
--- integers and floats use SQLite's text formatting; text and blobs
--- remain byte strings, including NUL.
function Sqlite.text_rows(handle: Sqlite.Handle, sql: string,
                           values?: {Sqlite.Value}): {{string}} | nil, string
  local statement, trouble = prepared(handle, sql, values)
  if statement == nil then
    return nil, trouble
  end
  return each_row(statement, texts_of)
end

--- Runs `work` inside a transaction and commits when it answers `true`.
--- When `work` answers `false` and why, or the commit fails, the
--- transaction rolls back and this answers `false` and that reason. When
--- `work` raises, the transaction rolls back and the same error is
--- raised again. A transaction already open on `handle` makes `BEGIN`
--- fail, so calls do not nest.
---
--- The statements of one transaction are written through the same
--- handle:
---
---     local ok, why = Sqlite.transact(db, function(): boolean, string
---       local a, trouble = Sqlite.run(db, "INSERT INTO t (body) VALUES (?1)", { { text = "a" } })
---       if not a then return false, trouble end
---       return Sqlite.run(db, "INSERT INTO t (body) VALUES (?1)", { { text = "b" } })
---     end)
function Sqlite.transact(handle: Sqlite.Handle,
                          work: function(): boolean, string): boolean, string
  local started, trouble = handle:exec("BEGIN")
  if not started then
    return false, trouble
  end
  local called, ok, why = pcall(work)
  if not called then
    local _, _ = handle:exec("ROLLBACK")
    error(ok, 0)
  end
  if not ok then
    local _, _ = handle:exec("ROLLBACK")
    return false, why
  end
  local committed, failure = handle:exec("COMMIT")
  if not committed then
    local _, _ = handle:exec("ROLLBACK")
    return false, failure
  end
  return true, ""
end

Sqlite.version = sqlite.version

return Sqlite
