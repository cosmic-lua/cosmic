--- Internal helper for cosmic.sqlite: caches prepared statements by SQL
--- text so db:exec can reuse a statement across repeated calls with the
--- same SQL (e.g. inside a loop in a transaction) instead of preparing
--- and finalizing a fresh one every time.

local record RawStatement
  bind: function(self: RawStatement, n: number, value?: any): number
  step: function(self: RawStatement): number
  reset: function(self: RawStatement)
  finalize: function(self: RawStatement): number
end

local record RawDatabase
  prepare: function(self: RawDatabase, sql: string): RawStatement, number, string
  errmsg: function(self: RawDatabase): string
end

local record StmtCache
  exec: function(self: StmtCache, sql: string, args: {integer: any}, n: integer): boolean, string
  close_all: function(self: StmtCache)
end

--- Create a statement cache bound to a raw database handle.
--- @param raw_db_any any The lsqlite3 database handle to prepare against
--- (typed `any` so callers don't need a nominally-identical RawDatabase type)
--- @param ok_code number lsqlite3.OK
--- @param done_code number lsqlite3.DONE
--- @param row_code number lsqlite3.ROW
--- @param schema_code number lsqlite3.SCHEMA
--- @return StmtCache
local function new(raw_db_any: any, ok_code: number, done_code: number, row_code: number, schema_code: number): StmtCache
  local raw_db = raw_db_any as RawDatabase
  local cache: {string: RawStatement} = {}
  local self: StmtCache = {}

  local function get(sql: string): RawStatement, string
    local cached = cache[sql]
    if cached then
      return cached
    end
    local raw_stmt, errcode, errmsg = raw_db:prepare(sql)
    if not raw_stmt then
      return nil, errmsg or ("error code " .. tostring(errcode))
    end
    cache[sql] = raw_stmt
    return raw_stmt
  end

  local function bind_and_step(raw_stmt: RawStatement, args: {integer: any}, n: integer): number
    raw_stmt:reset()
    for i = 1, n do
      local rc = raw_stmt:bind(i, args[i])
      if rc ~= ok_code then
        return rc
      end
    end
    return raw_stmt:step()
  end

  --- Finalize every cached statement, e.g. when the owning database closes.
  self.close_all = function(_: StmtCache)
    for sql, raw_stmt in pairs(cache) do
      local _ = raw_stmt:finalize()
      cache[sql] = nil
    end
  end

  --- Execute a parameterized statement once, reusing (or preparing and
  --- caching) the statement for `sql`. On SQLITE_SCHEMA, drops the stale
  --- statement and retries once (sqlite3 already retries internally
  --- before surfacing SCHEMA, so a second failure is a real error).
  function self:exec(sql: string, args: {integer: any}, n: integer): boolean, string
    local raw_stmt, err = get(sql)
    if not raw_stmt then
      return false, err
    end
    local rc = bind_and_step(raw_stmt, args, n)
    if rc == schema_code then
      cache[sql] = nil
      local _ = raw_stmt:finalize()
      raw_stmt, err = get(sql)
      if not raw_stmt then
        return false, err
      end
      rc = bind_and_step(raw_stmt, args, n)
    end
    if rc ~= done_code and rc ~= row_code then
      return false, raw_db:errmsg()
    end
    return true
  end

  return self
end

return {new = new}
