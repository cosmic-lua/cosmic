--- SQLite, typed.
---
--- The C boundary keeps a value's type: text and bytes are separate
--- calls, and a parameter is bound by naming what it is. This module
--- keeps that property and adds the shapes a caller wants: a query that
--- yields rows, a statement run once, and a transaction that rolls back
--- when the work inside it fails.

--- The raw module behind this one is never itself a name `require`
--- resolves -- see cosmic/Store.tl for why -- and arrives instead as
--- the second argument `require` passes this chunk's own loader,
--- present because this module was itself loaded, trusted, from the
--- binary's own tree. Boot mode falls back to requiring it by name,
--- which only boot's own preload answers.
local type raw_sqlite = require("cosmic.sqlite")

local extra: any = select(2, ...)
local sqlite: raw_sqlite
if type(extra) == "table" then
  sqlite = extra as raw_sqlite
else
  sqlite = require("cosmic.sqlite")
end

local record Sqlite
  Handle: raw_sqlite.Handle
  Statement: raw_sqlite.Statement

  --- One bound parameter. Its field says what SQLite is told it is, so
  --- a blob never arrives as text by accident.
  record Value
    integer: integer
    number: number
    text: string
    blob: string
  end

  --- The version of SQLite the core carries.
  version: string
end

--- A database file, read-only unless `writable` says otherwise.
function Sqlite.open(path: string, writable?: boolean): raw_sqlite.Handle | nil, string
  return sqlite.open(path, writable)
end

--- A database held in memory, which is where a build assembles one
--- before writing it out.
function Sqlite.memory(): raw_sqlite.Handle | nil, string
  return sqlite.open(":memory:", true)
end

local function bind(statement: raw_sqlite.Statement, values: {Sqlite.Value}): boolean, string
  for index, value in ipairs(values) do
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

--- Runs a statement that yields no rows.
function Sqlite.run(handle: raw_sqlite.Handle, sql: string,
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

--- Every row a query yields, each row a list of column values in order.
--- A text column and a blob column both arrive as strings; `kinds` says
--- which each one was.
function Sqlite.rows(handle: raw_sqlite.Handle, sql: string,
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
  return out
end

--- Runs `work` inside a transaction, rolling back when it fails.
function Sqlite.transact(handle: raw_sqlite.Handle,
                          work: function(): boolean, string): boolean, string
  local started, trouble = handle:exec("BEGIN")
  if not started then
    return false, trouble
  end
  local ok, why = work()
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

Sqlite.version = sqlite.version

return Sqlite
