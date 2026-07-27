--- Internal helper for cosmic.sqlite: the BLOB value marker and the shared
--- positional bind step. Every bind loop (Statement:bind/bind_list, the
--- db:exec statement cache, the db:query hot path) funnels through
--- `bind_at`, so a value wrapped with `blob()` is bound with SQLite blob
--- affinity everywhere instead of defaulting to TEXT.
--- Lives in its own file so cosmic/sqlite.tl stays under the 500-line cap.

local lsqlite3 = require("cosmo.lsqlite3")

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

local record M
  type Blob = Blob
  --- Statement release callback shared by stmt_cache (producer) and
  --- row_iter (consumer) so the two sides name one nominal type.
  type OnClose = function(lsqlite3.Statement)

  blob: function(data: string): Blob
  is_blob: function(v: any): boolean
  bind_at: function(raw_stmt: lsqlite3.Statement, i: integer, v: any): number
end

local mod: M = {
  blob = blob,
  is_blob = is_blob,
  bind_at = bind_at,
}

return mod
