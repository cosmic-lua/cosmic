--- SQLite, typed.
---
--- The C boundary keeps a value's type: text and bytes are separate
--- calls, and a parameter is bound by naming what it is. This module
--- keeps that property and adds the shapes a caller wants: a query that
--- yields rows, all at once (`rows`) or one at a time (`query`), a
--- statement run once, and a transaction that rolls back when the work
--- inside it fails.
---
--- A parameter is a one-field table naming its type, one per `?N`, in
--- order; a result cell carries its `kind` and the matching field:
---
---     local db = assert(Sqlite.open("notes.db", true))
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

--- The raw module behind this one lives under the reserved
--- `cosmic.internal.` namespace, which never satisfies an ordinary
--- `require` for any caller -- see cosmic/store.tl for why -- and
--- arrives instead as the second argument `require` passes this
--- chunk's own loader, present because this module was itself loaded,
--- trusted, from the binary's own tree. Boot mode falls back to
--- requiring it by name, which only boot's own preload answers.
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
  --- a blob never arrives as text by accident. Exactly one field is allowed;
  --- an empty table explicitly binds SQL NULL.
  record Value
    integer: integer
    number: number
    text: string
    blob: string
  end

  --- One query result value. `kind` is one of `"null"`, `"integer"`,
  --- `"number"`, `"text"`, or `"blob"`; exactly the matching value field is
  --- present, except that a null cell has no value field.
  record Cell
    kind: string
    integer: integer
    number: number
    text: string
    blob: string
  end

  type Row = {Cell}
  type Rows = {Row}

  --- A query's rows read one at a time: see `Sqlite.query`.
  record Query
    metamethod __close: function(Query)
    --- The next row, and ""; nil and "" after the last; nil and why
    --- when stepping failed, the same again on every later read.
    read: function(Query): Row | nil, string
    --- An iterator for a `for` loop over the rows still to come. It
    --- ends at the last one or at a failure, which `failure` then says.
    each: function(Query): function(): Row
    --- Why the rows ended early, or "" when they have not: after an
    --- `each` loop, "" means every row was read.
    failure: function(Query): string
    --- Finalizes the statement, so the handle can close; the last
    --- row, a failure and a `<close>` variable each do it too. A read
    --- afterward fails. Closing again does nothing.
    close: function(Query)
  end

  --- The version of SQLite the core carries.
  version: string
end

--- A database file, read-only unless `writable` says otherwise, in which
--- case a missing file is created. Every handle knows `sha256(X)`, the
--- 32-byte digest of a text or blob, `digest(A, X)`, the digest under
--- the algorithm A names (the names `cosmic.hash` takes), and
--- `hmac(A, K, X)`, the HMAC of X under key K over A; a NULL argument
--- gives NULL. `lower(hex(sha256(X)))` is the form the build writes
--- into keys. `deflate(X)` is the raw deflate of X, as
--- `Compress.deflate("raw", X)` writes it, and `inflate(X)` what such a
--- stream decodes to, as a blob: the shipped database stores each
--- module's source that way, so `CAST(inflate(source) AS TEXT)` reads it.
function Sqlite.open(path: string, writable?: boolean): Sqlite.Handle | nil, string
  return sqlite.open(path, writable)
end

--- A database held in memory, which is where a build assembles one
--- before writing it out.
function Sqlite.memory(): Sqlite.Handle | nil, string
  return sqlite.open(":memory:", true)
end

--- Binds SQLite parameters positionally. Parameter keys must be
--- positional (1..N, matching the statement's own placeholders), and
--- each value must be a table with exactly one field named integer,
--- number, text, or blob (use {} for NULL).
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

--- Parameters are a dense list indexed by SQLite's parameter index, through
--- its highest index. Repeated named parameters share an index; ?NNN gaps
--- still need entries (use {}). Missing entries and extra keys are errors.
--- Runs a statement that yields no rows.
function Sqlite.run(handle: Sqlite.Handle, sql: string,
                    values?: {Sqlite.Value}): boolean, string
  local statement, trouble = handle:prepare(sql)
  if statement == nil then
    return false, trouble
  end
  local bound, why = bind(statement, values or {})
  if not bound then
    statement:finalize()
    return false, why
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
function Sqlite.cell(statement: Sqlite.Statement, index: integer): Sqlite.Cell
  local kind = statement:kind(index)
  if kind == "integer" then
    return { kind = kind, integer = statement:integer(index) }
  elseif kind == "number" then
    return { kind = kind, number = statement:number(index) }
  elseif kind == "text" then
    return { kind = kind, text = statement:bytes(index) }
  elseif kind == "blob" then
    return { kind = kind, blob = statement:bytes(index) }
  end
  return { kind = "null" }
end

--- Parameters follow the same complete-list contract as run.
--- Every row a query yields, each row a dense list of typed cells in column
--- order. SQL NULL is an explicit `kind = "null"` cell.
function Sqlite.rows(handle: Sqlite.Handle, sql: string,
                      values?: {Sqlite.Value}): Sqlite.Rows | nil, string
  local statement, trouble = handle:prepare(sql)
  if statement == nil then
    return nil, trouble
  end
  local bound, why = bind(statement, values or {})
  if not bound then
    statement:finalize()
    return nil, why
  end
  local out: Sqlite.Rows = {}
  local width = statement:columns()
  while true do
    local state, failure = statement:step()
    if state == nil then
      statement:finalize()
      return nil, failure
    end
    if state == "done" then
      break
    end
    local row: Sqlite.Row = {}
    for index = 0, width - 1 do
      row[index + 1] = Sqlite.cell(statement, index)
    end
    out[#out + 1] = row
  end
  statement:finalize()
  return out, ""
end

local query_mt: metatable<Sqlite.Query> = {
  __close = function(self: Sqlite.Query)
    self:close()
  end,
}

--- Parameters follow the same complete-list contract as run.
--- A query whose rows are read one at a time, as `rows` gives them but
--- never all held at once: nil and why when the statement does not
--- prepare or bind. The statement stays open, and the handle cannot
--- close, until the last row is read, a step fails, or the query is
--- closed; hold it in a `<close>` variable to close it on a `break` or
--- an error too.
---
---     local q <close> = assert(Sqlite.query(db, "SELECT id, body FROM t"))
---     for row in q:each() do print(row[1].integer, row[2].text) end
---     assert(q:failure() == "", q:failure())
function Sqlite.query(handle: Sqlite.Handle, sql: string,
                      values?: {Sqlite.Value}): Sqlite.Query | nil, string
  local prepared, trouble = handle:prepare(sql)
  if prepared == nil then
    return nil, trouble
  end
  local statement: Sqlite.Statement = prepared
  local bound, why = bind(statement, values or {})
  if not bound then
    statement:finalize()
    return nil, why
  end
  local width = statement:columns()
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
    local state, failure = statement:step()
    if state == nil then
      failed = failure ~= "" and failure or "sqlite: the step failed"
      finish()
      return nil, failed
    end
    if state == "done" then
      ended = true
      finish()
      return nil, ""
    end
    local row: Sqlite.Row = {}
    for index = 0, width - 1 do
      row[index + 1] = Sqlite.cell(statement, index)
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

--- A direct text projection for callers whose SQL already defines the desired
--- coercion. SQLite's byte representation is returned for every value: NULL,
--- empty text, and empty blob all become `""`; integers and floats use
--- SQLite's text formatting; text and blobs remain byte strings, including NUL.
function Sqlite.text_rows(handle: Sqlite.Handle, sql: string,
                           values?: {Sqlite.Value}): {{string}} | nil, string
  local statement, trouble = handle:prepare(sql)
  if statement == nil then
    return nil, trouble
  end
  local bound, why = bind(statement, values or {})
  if not bound then
    statement:finalize()
    return nil, why
  end
  local out: {{string}} = {}
  local width = statement:columns()
  while true do
    local state, failure = statement:step()
    if state == nil then
      statement:finalize()
      return nil, failure
    end
    if state == "done" then
      break
    end
    local row: {string} = {}
    for index = 0, width - 1 do
      row[index + 1] = statement:bytes(index)
    end
    out[#out + 1] = row
  end
  statement:finalize()
  return out, ""
end

--- Runs `work` inside a transaction, rolling back when it fails.
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
