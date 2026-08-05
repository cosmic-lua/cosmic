--- Internal helper for cosmic.sqlite: caches prepared statements by SQL
--- text so db:exec can reuse a statement across repeated calls with the
--- same SQL (e.g. inside a loop in a transaction) instead of preparing
--- and finalizing a fresh one every time.

local bind_mod = require("cosmic.sqlite.bind")
local sqltext = require("cosmic.sqlite.sqltext")
local lsqlite3 = require("cosmo.lsqlite3")

-- sqlite compiles only the FIRST statement of a multi-statement string,
-- so running one through the parameterized paths would silently execute
-- a prefix and report success. Rejected instead — and only on the
-- prepare (cache-miss) path, so the hot cached path never re-scans.
local MULTI_ERR < const > =
"multi-statement sql is not supported here; run each statement"
.. " separately (only exec without parameters runs multi-statement sql)"

-- Named alias (shared through cosmic.sqlite.bind) so a function-typed
-- return value never appears as an inline literal in a multi-return
-- signature: that trips a bootstrap-compiler formatter bug.
local type OnClose = bind_mod.OnClose

local record StmtCache
  exec: function(self: StmtCache, sql: string, args: {integer: any}, n: integer): boolean, string
  checkout: function(self: StmtCache, sql: string): lsqlite3.Statement | nil, OnClose, string
  close_all: function(self: StmtCache)
end

--- Create a statement cache bound to a raw database handle.
--- @param raw_db lsqlite3.Database The database to prepare against
--- @param ok_code number lsqlite3.OK
--- @param done_code number lsqlite3.DONE
--- @param row_code number lsqlite3.ROW
--- @param schema_code number lsqlite3.SCHEMA
--- @return StmtCache
local function new(raw_db: lsqlite3.Database, ok_code: number, done_code: number, row_code: number, schema_code: number): StmtCache
  local cache: {string: lsqlite3.Statement} = {}
  -- Separate from `cache`: a query's statement stays alive for the life
  -- of its Rows iterator (unlike exec's synchronous prepare-bind-step),
  -- so it needs its own pool plus a checked-out flag per SQL text.
  local query_cache: {string: lsqlite3.Statement} = {}
  local checked_out: {string: boolean} = {}
  local self: StmtCache = {}

  local function get(sql: string): lsqlite3.Statement, string
    local cached = cache[sql]
    if cached then
      return cached
    end
    if sqltext.has_multiple_statements(sql) then
      return nil, MULTI_ERR
    end
    local raw_stmt = raw_db:prepare(sql)
    if not raw_stmt then
      return nil, raw_db:errmsg()
    end
    local stmt = raw_stmt
    cache[sql] = stmt
    return stmt
  end

  local function bind_and_step(raw_stmt: lsqlite3.Statement, args: {integer: any}, n: integer): number
    raw_stmt:reset()
    for i = 1, n do
      local rc = bind_mod.bind_at(raw_stmt, i, args[i])
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
    for sql, raw_stmt in pairs(query_cache) do
      local _ = raw_stmt:finalize()
      query_cache[sql] = nil
    end
  end

  --- Check out a statement for db:query, preparing and caching one if this
  --- SQL text hasn't been queried yet. Returns (statement, on_close):
  --- on_close is non-nil when the statement is the shared cached one —
  --- the caller must call it (instead of finalizing) when its Rows
  --- iterator finishes, to return the slot. When the cached slot for
  --- this SQL is already checked out by an unfinished query
  --- (nested/interleaved queries for the same SQL text), a fresh
  --- throwaway statement is prepared instead and on_close is nil — the
  --- caller finalizes it itself, same as an uncached prepare.
  function self:checkout(sql: string): lsqlite3.Statement | nil, OnClose, string
    local cached = query_cache[sql]
    if cached and not checked_out[sql] then
      checked_out[sql] = true
      return cached, function(_: lsqlite3.Statement) checked_out[sql] = nil end
    end
    if not cached and sqltext.has_multiple_statements(sql) then
      return nil, nil, MULTI_ERR
    end
    local raw_stmt = raw_db:prepare(sql)
    if not raw_stmt then
      return nil, nil, raw_db:errmsg()
    end
    -- prepare is Statement | nil once the pin carries the honest
    -- annotation; records don't flow-narrow, so cast after the guard.
    local stmt = raw_stmt
    if not cached then
      query_cache[sql] = stmt
      checked_out[sql] = true
      return stmt, function(_: lsqlite3.Statement) checked_out[sql] = nil end
    end
    return stmt, nil
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
