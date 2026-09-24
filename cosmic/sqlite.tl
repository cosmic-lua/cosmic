--- SQLite, typed.
---
--- The C boundary keeps a value's type: text and bytes are separate
--- calls, and a parameter is bound by naming what it is. This module
--- keeps that property and adds the shapes a caller wants: a query that
--- yields rows, a statement run once, and a transaction that rolls back
--- when the work inside it fails.
---
--- A parameter is a one-field table naming its type, one per `?N`, in
--- order; a result cell carries its `kind` and the matching field:
---
---     local db = assert(Sqlite.open("notes.db", true))
---     assert(Sqlite.exec(db, "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, body TEXT)"))
---     assert(Sqlite.run(db, "INSERT INTO t (body) VALUES (?1)", { { text = "hi" } }))
---     local rows = assert(Sqlite.rows(db, "SELECT id, body FROM t WHERE id = ?1",
---       { { integer = Sqlite.last_insert_rowid(db) } }))
---     print(rows[1][1].integer, rows[1][2].text) -- 1  hi
---
--- `{ integer = n }`, `{ number = x }`, `{ text = s }` and `{ blob = b }`
--- bind those types; `{}` binds NULL.

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

  --- The version of SQLite the core carries.
  version: string
end

--- A database file, read-only unless `writable` says otherwise, in which
--- case a missing file is created. Every handle knows `sha256(X)`, the
--- 32-byte digest of a text or blob, `digest(A, X)`, the digest under
--- the algorithm A names (the names `cosmic.hash` takes), and
--- `hmac(A, K, X)`, the HMAC of X under key K over A; a NULL argument
--- gives NULL. `lower(hex(sha256(X)))` is the form the build writes
--- into keys. Every handle also has vec1, the SQLite project's vector
--- search (https://sqlite.org/vec1): `CREATE VIRTUAL TABLE t USING
--- vec1(vector, meta...)`, then `SELECT rowid, distance FROM t(?1, k)`
--- for the k nearest to a vector, which is a blob of 32-bit floats in
--- the machine's order (`string.pack("=fff", x, y, z)`).
function Sqlite.open(path: string, writable?: boolean): Sqlite.Handle | nil, string
  return sqlite.open(path, writable)
end

--- A database held in memory, which is where a build assembles one
--- before writing it out.
function Sqlite.memory(): Sqlite.Handle | nil, string
  return sqlite.open(":memory:", true)
end

--- Runs sql against handle directly, with no parameter binding: schema
--- DDL, PRAGMAs, or several `;`-separated statements in one call --
--- the one thing `run`/`rows`/`text_rows` cannot do, since each of
--- those prepares exactly one statement. Yields no rows and binds no
--- values; reach for `Sqlite.run` instead once a value needs one.
function Sqlite.exec(handle: Sqlite.Handle, sql: string): boolean, string
  return handle:exec(sql)
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
    if type(key) ~= "number" then
      return false, "unexpected parameter key: " .. tostring(key)
    end
    local index = key as number
    if index % 1 ~= 0 or index < 1 or index > count then
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
      local kind = statement:kind(index)
      local cell: Sqlite.Cell
      if kind == "integer" then
        cell = { kind = kind, integer = statement:integer(index) }
      elseif kind == "number" then
        cell = { kind = kind, number = statement:number(index) }
      elseif kind == "text" then
        cell = { kind = kind, text = statement:bytes(index) }
      elseif kind == "blob" then
        cell = { kind = kind, blob = statement:bytes(index) }
      else
        cell = { kind = "null" }
      end
      row[index + 1] = cell
    end
    out[#out + 1] = row
  end
  statement:finalize()
  return out, ""
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
    handle:exec("ROLLBACK")
    error(ok, 0)
  end
  if not ok then
    handle:exec("ROLLBACK")
    return false, why
  end
  local committed, failure = handle:exec("COMMIT")
  if not committed then
    handle:exec("ROLLBACK")
    return false, failure
  end
  return true, ""
end

--- Closes the handle. Idempotent: closing an already-closed handle
--- still returns true.
function Sqlite.close(handle: Sqlite.Handle): boolean, string
  return handle:close()
end

--- Rows changed by the most recent INSERT, UPDATE, or DELETE on this
--- connection -- not the whole database, and not other statements
--- that happened to touch the same table concurrently.
function Sqlite.changes(handle: Sqlite.Handle): integer
  return handle:changes()
end

--- The rowid SQLite assigned the most recent successful INSERT on this
--- connection. 0 before any INSERT has ever run on it; a table
--- declared `WITHOUT ROWID` never changes it.
function Sqlite.last_insert_rowid(handle: Sqlite.Handle): integer
  return handle:last_insert_rowid()
end

Sqlite.version = sqlite.version

return Sqlite
