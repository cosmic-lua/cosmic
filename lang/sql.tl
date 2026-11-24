--- SQL read at check time against a schema ([`Sqlite.schema`] of [`cosmic.sqlite`]), for the checker's reads of
--- the SQL a program sends to a handle opened with one ([`lang.check`]).
---
--- The checker does not parse SQL: SQLite, which cosmic carries, prepares it in a memory
--- database that holds the schema, so SQLite's own dialect is what is read. Nothing is
--- run but the schema's DDL, once per text, with `ATTACH` refused: a prepare only compiles.

-- The core's binding, not cosmic.sqlite: the checker is in the seed a boot compiles
-- (build/seed.txt), which then needs no more than this.
local sqlite = require("cosmic.internal.sqlite")

local record Sql
  --- What SQLite says of one statement prepared against a schema.
  record Read
    --- SQLite's refusal, in its own words ("no such column: nme"); nil where it prepared.
    refused?: string
    --- How many values the statement binds: its highest `?N`.
    parameters: integer
  end

  --- The methods of a handle that take SQL first, each with whether a values list follows it.
  methods: {string: boolean}
end

Sql.methods = {
  run = true, rows = true, one = true, query = true, map = true, text_rows = true, prepare = false,
}

--- A schema's database, or SQLite's refusal of its DDL, by the DDL's text.
local record Held
  handle?: sqlite.Handle
  refused?: string
end

local held_schemas: mut {string: Held} = {}
local held_count = 0

--- How many schemas' databases are kept at once: a language server checks each version of a
--- schema as it is typed, and each is a new text.
local HELD_AT_MOST <const> = 32

--- How long the DDL may run, in nanoseconds, and how long a text or blob it makes may be: DDL
--- that runs forever (a recursive `CREATE TABLE ... AS`) or fills memory stops there.
local DDL_TIME_NS <const> = 1000000000
local VALUE_BYTES <const> = 1000000

--- Each statement of `ddl` run in a new memory database, or SQLite's refusal.
local function made(ddl: string): Held
  if ddl:find("\0", 1, true) ~= nil then return { refused = "a schema's DDL cannot hold a NUL" } end
  local opened = sqlite.open_result(":memory:", true, nil, nil, true)
  if opened.code ~= 0 then return { refused = opened.reason } end
  local handle = opened.handle
  local _ = handle:limit("attached", 0)
  local _ = handle:limit("length", VALUE_BYTES)
  handle:time_limit(DDL_TIME_NS)
  local ran = handle:exec_result(ddl)
  if ran.code ~= 0 then
    local _, _ = handle:close()
    return { refused = if ran.timed_out == true then "the DDL ran past " .. tostring(DDL_TIME_NS // 1000000) ..
        " ms at check time" else ran.reason end }
  end
  local tables, _ = handle:prepare("SELECT count(*) FROM sqlite_schema WHERE type = 'table'")
  local has_tables = false
  if tables ~= nil then
    local stepped, _ = tables:step()
    has_tables = stepped == "row" and tables:integer(0) > 0
    tables:finalize()
  end
  if not has_tables then
    local _, _ = handle:close()
    return { refused = "the DDL creates no table" }
  end
  handle:time_limit(nil)
  return { handle = handle }
end

local function hold(ddl: string): Held
  local known = held_schemas[ddl]
  if known ~= nil then return known end
  if held_count >= HELD_AT_MOST then
    for _, held in pairs(held_schemas) do
      local handle = held.handle
      if handle ~= nil then local _, _ = handle:close() end
    end
    held_schemas, held_count = {}, 0
  end
  local found = made(ddl)
  held_schemas[ddl] = found
  held_count = held_count + 1
  return found
end

--- SQLite's refusal of a schema's DDL, or nil where it runs.
function Sql.schema(ddl: string): string?
  return hold(ddl).refused
end

--- What SQLite says of `sql` against the schema `ddl`: nil where the DDL itself is refused
--- ([`Sql.schema`]), or where `sql` names an attached database or a table of one, which the
--- schema does not cover.
function Sql.read(ddl: string, sql: string): Sql.Read?
  local handle = hold(ddl).handle
  if handle == nil then return nil end
  -- The core raises for SQL that holds no statement, or more than one.
  local called, statement, why = pcall(function(): (sqlite.Statement?, string)
    return handle:prepare(sql)
  end)
  if not called then
    return { refused = tostring(statement):gsub("^.-: ", "", 1), parameters = 0 }
  end
  if statement == nil then
    -- An attached database's tables are not the schema's.
    local prefix = why:match("^no such table: ([%w_]+)%.")
    if (prefix ~= nil and prefix ~= "main" and prefix ~= "temp") or why:find("^unknown database ") ~= nil then
      return nil
    end
    return { refused = why, parameters = 0 }
  end
  local count = statement:parameters()
  statement:finalize()
  return { parameters = count }
end

--- Whether `sql` changes what a handle holds beyond its schema: a `CREATE`, `DROP`, `ALTER`,
--- `ATTACH` or `DETACH` in it. SQL sent after it is no longer read against the schema alone.
function Sql.changes_schema(sql: string): boolean
  local upper = sql:upper()
  for _, word in ipairs({ "CREATE", "DROP", "ALTER", "ATTACH", "DETACH" }) do
    if upper:find("%f[%w_]" .. word .. "%f[^%w_]") ~= nil then return true end
  end
  return false
end

return Sql
