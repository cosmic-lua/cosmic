--- Internal helper for cosmic.sqlite: the BLOB value marker and the shared
--- bind step. Every bind loop (Statement:bind/bind_list/bind_named, the
--- db:exec statement cache, the db:query hot path) funnels through
--- `bind_at`, so a value wrapped with `blob()` is bound with SQLite blob
--- affinity everywhere instead of defaulting to TEXT.
--- Lives in its own file so cosmic/sqlite.tl stays under the 500-line cap.

local lsqlite3 = require("cosmo.lsqlite3")

--- One Params argument covers both binding styles: a non-empty array
--- part (`{v1, v2}`) binds positionally to `?` placeholders, anything
--- else (`{name = v}`) binds its keys to `:name` placeholders. An
--- empty table binds nothing (unbound placeholders are SQL NULL). The
--- two styles do not mix in one call — a table with both an array
--- part and string keys binds positionally. Typed `table` because
--- Teal cannot union two table types; the shape rule is this doc.
local type Params = table

--- Marker wrapper produced by `cosmic.sqlite.blob()`. Bind loops detect it
--- by metatable identity and bind `data` via `bind_blob` instead of `bind`.
local record Blob
  data: string
end

-- Identity marker: getmetatable(v) == blob_mt is the only blob test, so a
-- plain {data = ...} table can never be mistaken for a blob.
local blob_mt: metatable < Blob > = {}

--- Wrap a string so bind loops store it with BLOB affinity.
--- @param data string The raw bytes to bind as a BLOB
--- @return Blob The marker wrapper recognized by every bind path
local function blob(data: string): Blob
  return setmetatable({data = data}, blob_mt)
end

--- Report whether a value is a `blob()` wrapper.
--- @param v any The value to test
--- @return boolean true when v was produced by blob()
local function is_blob(v: any): boolean
  return getmetatable(v) == blob_mt as any -- cast: metatable identity compare
end

--- Bind one positional parameter, routing blob() wrappers to bind_blob.
--- @param raw_stmt lsqlite3.Statement The prepared statement to bind into
--- @param i integer 1-based parameter index
--- @param v any The value (or blob() wrapper) to bind
--- @return number The sqlite result code from the bind call
local function bind_at(raw_stmt: lsqlite3.Statement, i: integer, v: any): number
  if getmetatable(v) == blob_mt as any then -- cast: metatable identity compare
    return raw_stmt:bind_blob(i, (v as Blob).data) -- cast: from any
  end
  return raw_stmt:bind(i, v as string | number | boolean) -- cast: from any
end

--- Bind a positional list. The count comes from the SQL, so nil holes
--- in the table bind as NULL.
--- @param raw_stmt lsqlite3.Statement The prepared statement to bind into
--- @param ok_code number lsqlite3.OK
--- @param values {any} Positional values for the `?` placeholders
--- @return number The first failing bind's result code, or ok_code
local function bind_list(raw_stmt: lsqlite3.Statement, ok_code: number, values: {any}): number
  local count = raw_stmt:bind_parameter_count()
  for i = 1, count do
    local rc = bind_at(raw_stmt, i, values[i])
    if rc ~= ok_code then
      return rc
    end
  end
  return ok_code
end

--- Bind `:name` placeholders from a key/value table (keys without the
--- colon). Iterates the statement's own parameter list and routes each
--- value through bind_at, so blob() wrappers get BLOB affinity here
--- too. A name missing from the table binds as NULL, matching the
--- positional nil-hole rule.
--- @param raw_stmt lsqlite3.Statement The prepared statement to bind into
--- @param ok_code number lsqlite3.OK
--- @param params {string: any} Values keyed by placeholder name
--- @return number The first failing bind's result code, or ok_code
local function bind_named(raw_stmt: lsqlite3.Statement, ok_code: number, params: {string: any}): number
  local count = raw_stmt:bind_parameter_count()
  for i = 1, count do
    local name = raw_stmt:bind_parameter_name(i)
    local v: any = nil
    if name then
      -- The binding reports names with their prefix (":name"); the
      -- table keys carry none.
      v = params[name:sub(2)]
    end
    local rc = bind_at(raw_stmt, i, v)
    if rc ~= ok_code then
      return rc
    end
  end
  return ok_code
end

--- Bind one Params table, dispatching on its shape: a non-empty array
--- part binds positionally, other non-empty tables bind by name, an
--- empty table binds nothing.
--- @param raw_stmt lsqlite3.Statement The prepared statement to bind into
--- @param ok_code number lsqlite3.OK
--- @param params Params The parameter table
--- @return number The first failing bind's result code, or ok_code
local function bind_params(raw_stmt: lsqlite3.Statement, ok_code: number, params: Params): number
  local list = params as {any} -- cast: array-part probe of the params table
  if #list > 0 then
    return bind_list(raw_stmt, ok_code, list)
  end
  local named = params as {string: any} -- cast: map view of the params table
  if next(named) ~= nil then
    return bind_named(raw_stmt, ok_code, named)
  end
  return ok_code
end

local record M
  type Blob = Blob
  type Params = Params
  --- Statement release callback shared by stmt_cache (producer) and
  --- row_iter (consumer) so the two sides name one nominal type.
  type OnClose = function(lsqlite3.Statement)

  blob: function(data: string): Blob
  is_blob: function(v: any): boolean
  bind_at: function(raw_stmt: lsqlite3.Statement, i: integer, v: any): number
  bind_list: function(raw_stmt: lsqlite3.Statement, ok_code: number, values: {any}): number
  bind_named: function(raw_stmt: lsqlite3.Statement, ok_code: number, params: {string: any}): number
  bind_params: function(raw_stmt: lsqlite3.Statement, ok_code: number, params: Params): number
end

local mod: M = {
  blob = blob,
  is_blob = is_blob,
  bind_at = bind_at,
  bind_list = bind_list,
  bind_named = bind_named,
  bind_params = bind_params,
}

return mod
