--- Internal helper for cosmic.sqlite: the list/named parameter convenience
--- methods (exec_list, exec_named, query_list, query_named) attached onto a
--- Database. They all follow the same prepare/bind/consume shape, so they
--- live together here. Lives in its own file so cosmic/sqlite.tl stays
--- under the 500-line cap.

local sqltext = require("cosmic.sqlite.sqltext")

-- Mirrors of cosmic.sqlite's records (Teal records are nominal, so the
-- boundary crosses through `any`; same convention as sqlite_stmt_cache).
local record Rows
  metamethod __call: function(self: Rows): {string: any}
  metamethod __close: function(self: Rows)
  err: function(self: Rows): string | nil
  close: function(self: Rows)
end

-- Same rejection as cosmic.sqlite.stmt_cache: prepare compiles only the
-- first statement, so a parameterized multi-statement call would
-- silently run a prefix. These paths prepare fresh every call, so the
-- scan runs per call — they are the documented slow path.
local MULTI_ERR < const > =
"multi-statement sql is not supported here; run each statement"
.. " separately (only exec without parameters runs multi-statement sql)"

local record Stmt
  bind_list: function(self: Stmt, values: {any}): boolean, string
  bind_named: function(self: Stmt, params: {string: any}): boolean, string
  exec: function(self: Stmt): boolean, string
  rows: function(self: Stmt): Rows
  close: function(self: Stmt)
end

local record Db
  prepare: function(self: Db, sql: string): Stmt | nil, string
  exec_list: function(self: Db, sql: string, values: {any}): boolean, string
  exec_named: function(self: Db, sql: string, params: {string: any}): boolean, string
  query_list: function(self: Db, sql: string, values: {any}): Rows | nil, string
  query_named: function(self: Db, sql: string, params: {string: any}): Rows | nil, string
end

-- Wrap a prepared+bound statement's row iterator: finalize the statement
-- when iteration ends and forward the step error through `:err()`.
-- `close` (also wired to `<close>` scope exit and garbage collection)
-- finalizes the statement when iteration is abandoned early.
local function make_query_iter(stmt: Stmt): Rows
  local raw_iter = stmt:rows()
  local done = false
  local function release()
    if done then
      return
    end
    done = true
    stmt:close()
  end
  local iter = setmetatable({} as Rows, { -- cast: table seeded as record
      __call = function(_: Rows): {string: any}
        if done then
          return nil
        end
        local row = raw_iter()
        if row == nil then
          release()
          return nil
        end
        return row
      end,
      __close = function(_: Rows)
        release()
      end,
      __gc = function(_: Rows)
        release()
      end,
    })
  iter.err = function(_: Rows): string | nil return raw_iter:err() end
  iter.close = function(_: Rows)
    release()
  end
  return iter
end

--- Attach the list/named parameter methods to a Database under
--- construction. The handle is typed `any` so cosmic.sqlite's nominal
--- Database record doesn't need to be duplicated here.
--- @param db_any any The Database being built by make_database
local function attach(db_any: any)
  local db = db_any as Db -- cast: from any

  --- Execute SQL with parameters from a list table. The count is derived
  --- from the SQL itself, so nil values in the table are handled correctly.
  function db:exec_list(sql: string, values: {any}): boolean, string
    if sqltext.has_multiple_statements(sql) then
      return false, MULTI_ERR
    end
    local stmt, err = self:prepare(sql)
    if not stmt then
      return false, err or "prepare failed"
    end
    local st = stmt

    local ok, bind_err = st:bind_list(values)
    if not ok then
      st:close()
      return false, bind_err or "bind failed"
    end

    local exec_ok, exec_err = st:exec()
    st:close()
    return exec_ok, exec_err
  end

  --- Execute SQL with named parameters.
  --- SQL should use :name placeholders. Table keys are names without the colon.
  function db:exec_named(sql: string, params: {string: any}): boolean, string
    if sqltext.has_multiple_statements(sql) then
      return false, MULTI_ERR
    end
    local stmt, err = self:prepare(sql)
    if not stmt then
      return false, err or "prepare failed"
    end
    local st = stmt

    local ok, bind_err = st:bind_named(params)
    if not ok then
      st:close()
      return false, bind_err or "bind failed"
    end

    local exec_ok, exec_err = st:exec()
    st:close()
    return exec_ok, exec_err
  end

  --- Query with parameters from a list table.
  --- The parameter count is derived from the SQL itself, so nil values
  --- in the table are handled correctly.
  function db:query_list(sql: string, values: {any}): Rows | nil, string
    if sqltext.has_multiple_statements(sql) then
      return nil, MULTI_ERR
    end
    local stmt, err = self:prepare(sql)
    if not stmt then
      return nil, "query failed: " .. (err or "unknown error")
    end
    local st = stmt

    local ok, bind_err = st:bind_list(values)
    if not ok then
      st:close()
      return nil, "bind failed: " .. (bind_err or "unknown error")
    end

    return make_query_iter(st)
  end

  --- Query with named parameters.
  --- SQL should use :name placeholders. Table keys are names without the colon.
  function db:query_named(sql: string, params: {string: any}): Rows | nil, string
    if sqltext.has_multiple_statements(sql) then
      return nil, MULTI_ERR
    end
    local stmt, err = self:prepare(sql)
    if not stmt then
      return nil, "query failed: " .. (err or "unknown error")
    end
    local st = stmt

    local ok, bind_err = st:bind_named(params)
    if not ok then
      st:close()
      return nil, "bind failed: " .. (bind_err or "unknown error")
    end

    return make_query_iter(st)
  end
end

return {attach = attach}
