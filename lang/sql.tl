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
    --- Each result column, in order; empty where the SQL was refused.
    columns: {Column}
  end

  --- What a column's declared type says of its cells: "integer" for a type that holds `INT`,
  --- "text" for `CHAR`, `CLOB` or `TEXT`, "number" for `REAL`, `FLOA` or `DOUB` (SQLite's rules
  --- for a type's affinity, in their order), and "blob" for `BLOB` in a `STRICT` table. A column
  --- with no such type (`NUMERIC`, `ANY`, none), or that is an expression, has no kind.
  enum Kind
    "integer"
    "text"
    "number"
    "blob"
  end

  --- One result column of a statement.
  record Column
    --- The table and its column the result column reads, as `notes.body`; nil for an expression.
    origin?: string
    --- The column's declared type, as the DDL writes it; nil for an expression or none.
    declared?: string
    --- Nil for an expression, and for every column of a compound select (`UNION`) or of SQL that
    --- reads a view that is one, whose later arms may give cells of any type.
    kind?: Kind
    --- Whether its table is `STRICT`, so that every cell is of the declared type or NULL; a
    --- table that is not may hold any cell in any column, as a text it cannot convert.
    strict: boolean
  end

  --- The methods of a handle that take SQL first, each with whether a values list follows it.
  methods: {string: boolean}

  --- The reads of a row's column that are held to its kind, each with true.
  row_reads: {string: boolean}
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

--- Closes every schema's database, and forgets them.
local function forget_all()
  for _, held in pairs(held_schemas) do
    local handle = held.handle
    if handle ~= nil then local _, _ = handle:close() end
  end
  held_schemas, held_count = {}, 0
end

local function hold(ddl: string): Held
  local known = held_schemas[ddl]
  if known ~= nil then return known end
  if held_count >= HELD_AT_MOST then forget_all() end
  local found = made(ddl)
  held_schemas[ddl] = found
  held_count = held_count + 1
  return found
end

--- SQLite's refusal of a schema's DDL, or nil where it runs.
function Sql.schema(ddl: string): string?
  return hold(ddl).refused
end

--- Whether `name` is a `STRICT` table of `handle`'s main database.
local function is_strict(handle: sqlite.Handle, name: string): boolean
  local statement, _ = handle:prepare("SELECT strict FROM pragma_table_list WHERE schema = 'main' AND name = ?1")
  if statement == nil then return false end
  local bound, _ = statement:bind_text(1, name)
  local stepped: string? = nil
  if bound then
    local step, _ = statement:step()
    stepped = step
  end
  local strict = stepped == "row" and statement:integer(0) == 1
  statement:finalize()
  return strict
end

local COMPOUND <const> = { "UNION", "INTERSECT", "EXCEPT" }

--- Whether `upper`, SQL in capitals, holds a compound select's word.
local function holds_compound(upper: string): boolean
  for _, word in ipairs(COMPOUND) do
    if upper:find("%f[%w_]" .. word .. "%f[^%w_]") ~= nil then return true end
  end
  return false
end

--- Whether `upper`, SQL in capitals, names a view of `handle` that is a compound select: SQLite gives a column of
--- such a view the origin of its first arm, whose type the later arms need not keep.
local function reads_compound_view(handle: sqlite.Handle, upper: string): boolean
  local statement, _ = handle:prepare("SELECT name, sql FROM sqlite_schema WHERE type = 'view'")
  if statement == nil then return false end
  local found = false
  while not found do
    local step, _ = statement:step()
    if step ~= "row" then break end
    local name = statement:bytes(0):upper()
    if holds_compound(statement:bytes(1):upper()) and
        upper:find("%f[%w_]" .. (name:gsub("%p", "%%%0")) .. "%f[^%w_]") ~= nil then
      found = true
    end
  end
  statement:finalize()
  return found
end

--- What `handle:prepare(sql)` gave: the statement, or SQLite's refusal; or the text of what the
--- core raised, for SQL that holds no statement or more than one, and for a handle a copy of the
--- process holds.
local record Prepared
  statement?: sqlite.Statement
  refusal: string
  raised?: string
end

local function try_prepare(handle: sqlite.Handle, sql: string): Prepared
  local called, statement, why = pcall(function(): (sqlite.Statement?, string)
    return handle:prepare(sql)
  end)
  if not called then return { refusal = "", raised = tostring(statement) } end
  return { statement = statement, refusal = why }
end

--- What SQLite says of `sql` against the schema `ddl`: nil where the DDL itself is refused
--- ([`Sql.schema`]), or where `sql` names an attached database or a table of one, or a `temp.` table, which the
--- schema does not cover.
function Sql.read(ddl: string, sql: string): Sql.Read?
  local first = hold(ddl).handle
  if first == nil then return nil end
  local handle = first
  local prepared = try_prepare(handle, sql)
  local raised = prepared.raised
  if raised ~= nil and raised:find("disowned its connections", 1, true) ~= nil then
    -- A copy of the process (a worker the checker forked) opens databases of its own.
    forget_all()
    local fresh = hold(ddl).handle
    if fresh == nil then return nil end
    handle = fresh
    prepared = try_prepare(handle, sql)
    raised = prepared.raised
  end
  if raised ~= nil then
    return { refused = (raised:gsub("^.-: ", "", 1)), parameters = 0, columns = {} }
  end
  local statement, why = prepared.statement, prepared.refusal
  if statement == nil then
    -- An attached database's tables are not the schema's, nor are the temporary tables a program makes as it runs.
    local prefix = why:match("^no such table: ([%w_]+)%.")
    if (prefix ~= nil and prefix ~= "main") or why:find("^unknown database ") ~= nil then
      return nil
    end
    return { refused = why, parameters = 0, columns = {} }
  end
  local count = statement:parameters()
  local upper = sql:upper()
  local compound = holds_compound(upper) or reads_compound_view(handle, upper)
  local columns: mut {Sql.Column} = {}
  for index = 0, statement:columns() - 1 do
    local table_name, column_name, declared = statement:origin(index)
    local origin = if table_name ~= nil and column_name ~= nil then table_name .. "." .. column_name else nil end
    local strict = table_name ~= nil and is_strict(handle, table_name)
    local kind = if origin ~= nil and declared ~= nil and not compound then Sql.kind(declared, strict) else nil end
    columns[#columns + 1] = { origin = origin, declared = declared, kind = kind, strict = strict }
  end
  statement:finalize()
  return { parameters = count, columns = columns }
end

--- The kind of a column declared `declared`, by SQLite's rules for its affinity, in their order;
--- a `BLOB` column is "blob" only in a `STRICT` table.
function Sql.kind(declared: string, strict: boolean): Sql.Kind?
  local upper = declared:upper()
  if upper:find("INT", 1, true) ~= nil then return "integer" end
  if upper:find("CHAR", 1, true) ~= nil or upper:find("CLOB", 1, true) ~= nil or upper:find("TEXT", 1, true) ~= nil then
    return "text"
  end
  if upper:find("BLOB", 1, true) ~= nil then return if strict then "blob" else nil end end
  if upper:find("REAL", 1, true) ~= nil or upper:find("FLOA", 1, true) ~= nil or upper:find("DOUB", 1, true) ~= nil then
    return "number"
  end
  return nil
end

Sql.row_reads = { integer = true, number = true, text = true, blob = true, bytes = true }

--- The reads that raise on every cell of a column's declared type, by its kind. A `STRICT` table
--- holds only such cells (or NULL, on which every read raises). A table that is not may keep a
--- text it cannot convert, or a blob, in any column, but the declared type says what the column
--- is for: a column that holds cells of other types is read with `as_text`, `kind` or `value`.
--- A `BLOB` column of such a table has no affinity, and no kind.
local REFUSALS <const>: {Sql.Kind: {string: boolean}} = {
  integer = { text = true, blob = true, bytes = true },
  number = { integer = true, text = true, blob = true, bytes = true },
  text = { integer = true, number = true, blob = true },
  blob = { integer = true, number = true, text = true },
}

--- Whether the read `method` raises on every cell of `column`'s declared type.
function Sql.refuses(column: Sql.Column, method: string): boolean
  local kind = column.kind
  if kind == nil then return false end
  local refusals = REFUSALS[kind]
  return refusals ~= nil and refusals[method] == true
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
