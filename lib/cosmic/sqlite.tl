--- Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns.
--- Wraps lsqlite3 with proper error returns and resource management.

local lsqlite3 = require("cosmo.lsqlite3")

-- Raw lsqlite3 types (0-indexed, requires manual cleanup)
local record RawStatement
  bind_values: function(self: RawStatement, ...: any): number
  bind: function(self: RawStatement, n: number, value?: any): number
  bind_names: function(self: RawStatement, params: {string:any}): number
  bind_parameter_count: function(self: RawStatement): number
  step: function(self: RawStatement): number
  reset: function(self: RawStatement)
  finalize: function(self: RawStatement): number
  get_value: function(self: RawStatement, n: number): any
  columns: function(self: RawStatement): number
  get_name: function(self: RawStatement, n: number): string
end

local record RawDatabase
  close: function(self: RawDatabase): number
  exec: function(self: RawDatabase, sql: string): number
  prepare: function(self: RawDatabase, sql: string): RawStatement, number, string
  last_insert_rowid: function(self: RawDatabase): number
  changes: function(self: RawDatabase): number
  errmsg: function(self: RawDatabase): string
end

local record RawSqlite3
  OK: number
  ROW: number
  DONE: number
  open: function(filename: string): RawDatabase, number, string
end

local sqlite3 = lsqlite3 as RawSqlite3

--- Statement handle with automatic cleanup.
local record Statement
  bind: function(self: Statement, ...: any): boolean, string
  bind_list: function(self: Statement, values: {any}): boolean, string
  bind_named: function(self: Statement, params: {string:any}): boolean, string
  rows: function(self: Statement): function(): {string:any}
  values: function(self: Statement): function(): any...
  exec: function(self: Statement): boolean, string
  reset: function(self: Statement)
  columns: function(self: Statement): number
  column_name: function(self: Statement, n: number): string
  close: function(self: Statement)
end

--- Database handle with automatic cleanup.
local record Database
  prepare: function(self: Database, sql: string): Statement, string
  query: function(self: Database, sql: string, ...: any): function(): {string:any}
  query_list: function(self: Database, sql: string, values: {any}): function(): {string:any}
  query_named: function(self: Database, sql: string, params: {string:any}): function(): {string:any}
  query_one: function(self: Database, sql: string, ...: any): {string:any}
  exec: function(self: Database, sql: string, ...: any): boolean, string
  exec_list: function(self: Database, sql: string, values: {any}): boolean, string
  exec_named: function(self: Database, sql: string, params: {string:any}): boolean, string
  transaction: function(self: Database, fn: function(Database)): boolean, string
  last_insert_rowid: function(self: Database): number
  changes: function(self: Database): number
  close: function(self: Database)
end

local function make_statement(raw_stmt: RawStatement, raw_db: RawDatabase): Statement
  local stmt: Statement = {}
  local closed = false

  --- Bind parameters by position. Handles trailing nil values correctly
  --- (unlike varargs with table.unpack which drops them).
  function stmt:bind(...: any): boolean, string
    raw_stmt:reset()
    local n = select("#", ...) as integer
    for i = 1, n do
      local val = select(i, ...)
      local rc = raw_stmt:bind(i, val)
      if rc ~= sqlite3.OK then
        return false, raw_db:errmsg()
      end
    end
    return true
  end

  --- Bind parameters from a list (table).
  --- The parameter count is derived from the SQL statement itself, so
  --- nil values in the table are handled correctly without an explicit count.
  function stmt:bind_list(values: {any}): boolean, string
    raw_stmt:reset()
    local count = raw_stmt:bind_parameter_count() as integer
    for i = 1, count do
      local rc = raw_stmt:bind(i, values[i as integer])
      if rc ~= sqlite3.OK then
        return false, raw_db:errmsg()
      end
    end
    return true
  end

  --- Bind named parameters from a key/value table.
  --- SQL should use :name placeholders (e.g. ":foo", ":bar").
  --- Table keys are names without the colon prefix.
  function stmt:bind_named(params: {string:any}): boolean, string
    raw_stmt:reset()
    local rc = raw_stmt:bind_names(params)
    if rc ~= sqlite3.OK then
      return false, raw_db:errmsg()
    end
    return true
  end

  function stmt:rows(): function(): {string:any}
    local col_count = raw_stmt:columns()
    local col_names: {integer:string}
    local first_call = true

    return function(): {string:any}
      local rc = raw_stmt:step()
      if rc == sqlite3.ROW then
        -- Get column names on first row (requires step to be called first)
        if first_call then
          first_call = false
          col_names = {}
          for idx = 0, col_count - 1 do
            col_names[(idx + 1) as integer] = raw_stmt:get_name(idx)
          end
        end
        local row: {string:any} = {}
        for idx = 0, col_count - 1 do
          local name = col_names[(idx + 1) as integer]
          row[name] = raw_stmt:get_value(idx)
        end
        return row
      end
      return nil
    end
  end

  function stmt:values(): function(): any...
    local col_count = raw_stmt:columns()

    return function(): any...
      local rc = raw_stmt:step()
      if rc == sqlite3.ROW then
        local vals: {integer:any} = {}
        for idx = 0, col_count - 1 do
          vals[(idx + 1) as integer] = raw_stmt:get_value(idx)
        end
        return table.unpack(vals)
      end
      return nil
    end
  end

  function stmt:exec(): boolean, string
    local rc = raw_stmt:step()
    if rc ~= sqlite3.DONE and rc ~= sqlite3.ROW then
      return false, raw_db:errmsg()
    end
    return true
  end

  stmt.reset = function(_: Statement)
    raw_stmt:reset()
  end

  stmt.columns = function(_: Statement): number
    return raw_stmt:columns()
  end

  stmt.column_name = function(_: Statement, n: number): string
    return raw_stmt:get_name(n - 1)
  end

  stmt.close = function(_: Statement)
    if not closed then
      closed = true
      local _ = raw_stmt:finalize()
    end
  end

  return setmetatable(stmt, {
    __close = function(self: Statement) self:close() end
  }) as Statement
end

local function make_database(raw_db: RawDatabase): Database
  local db: Database = {}
  local closed = false

  function db:prepare(sql: string): Statement, string
    local raw_stmt, errcode, errmsg = raw_db:prepare(sql)
    if not raw_stmt then
      return nil, errmsg or ("error code " .. tostring(errcode))
    end
    return make_statement(raw_stmt, raw_db)
  end

  function db:query(sql: string, ...: any): function(): {string:any}
    local stmt, err = self:prepare(sql)
    if not stmt then
      return function(): {string:any}
        error("query failed: " .. (err or "unknown error"))
      end
    end

    local n = select("#", ...) as integer
    if n > 0 then
      local ok, bind_err = stmt:bind(...)
      if not ok then
        stmt:close()
        return function(): {string:any}
          error("bind failed: " .. (bind_err or "unknown error"))
        end
      end
    end

    local raw_iter = stmt:rows()
    local done = false
    return function(): {string:any}
      if done then
        return nil
      end
      local row = raw_iter()
      if row == nil then
        done = true
        stmt:close()
        return nil
      end
      return row
    end
  end

  function db:exec(sql: string, ...: any): boolean, string
    local n = select("#", ...) as integer
    if n == 0 then
      -- no params: use raw exec (faster for DDL)
      local rc = raw_db:exec(sql)
      if rc ~= sqlite3.OK then
        return false, raw_db:errmsg()
      end
      return true
    end

    -- has params: prepare/bind/exec
    local stmt, err = self:prepare(sql)
    if not stmt then
      return false, err or "prepare failed"
    end

    local ok, bind_err = stmt:bind(...)
    if not ok then
      stmt:close()
      return false, bind_err or "bind failed"
    end

    local exec_ok, exec_err = stmt:exec()
    stmt:close()
    return exec_ok, exec_err
  end

  --- Execute SQL with parameters from a list (table).
  --- The parameter count is derived from the SQL itself, so nil values
  --- in the table are handled correctly.
  function db:exec_list(sql: string, values: {any}): boolean, string
    local stmt, err = self:prepare(sql)
    if not stmt then
      return false, err or "prepare failed"
    end

    local ok, bind_err = stmt:bind_list(values)
    if not ok then
      stmt:close()
      return false, bind_err or "bind failed"
    end

    local exec_ok, exec_err = stmt:exec()
    stmt:close()
    return exec_ok, exec_err
  end

  --- Execute SQL with named parameters.
  --- SQL should use :name placeholders. Table keys are names without the colon.
  function db:exec_named(sql: string, params: {string:any}): boolean, string
    local stmt, err = self:prepare(sql)
    if not stmt then
      return false, err or "prepare failed"
    end

    local ok, bind_err = stmt:bind_named(params)
    if not ok then
      stmt:close()
      return false, bind_err or "bind failed"
    end

    local exec_ok, exec_err = stmt:exec()
    stmt:close()
    return exec_ok, exec_err
  end

  --- Query with parameters from a list (table).
  --- The parameter count is derived from the SQL itself, so nil values
  --- in the table are handled correctly.
  function db:query_list(sql: string, values: {any}): function(): {string:any}
    local stmt, err = self:prepare(sql)
    if not stmt then
      return function(): {string:any}
        error("query failed: " .. (err or "unknown error"))
      end
    end

    local ok, bind_err = stmt:bind_list(values)
    if not ok then
      stmt:close()
      return function(): {string:any}
        error("bind failed: " .. (bind_err or "unknown error"))
      end
    end

    local raw_iter = stmt:rows()
    local done = false
    return function(): {string:any}
      if done then
        return nil
      end
      local row = raw_iter()
      if row == nil then
        done = true
        stmt:close()
        return nil
      end
      return row
    end
  end

  --- Query with named parameters.
  --- SQL should use :name placeholders. Table keys are names without the colon.
  function db:query_named(sql: string, params: {string:any}): function(): {string:any}
    local stmt, err = self:prepare(sql)
    if not stmt then
      return function(): {string:any}
        error("query failed: " .. (err or "unknown error"))
      end
    end

    local ok, bind_err = stmt:bind_named(params)
    if not ok then
      stmt:close()
      return function(): {string:any}
        error("bind failed: " .. (bind_err or "unknown error"))
      end
    end

    local raw_iter = stmt:rows()
    local done = false
    return function(): {string:any}
      if done then
        return nil
      end
      local row = raw_iter()
      if row == nil then
        done = true
        stmt:close()
        return nil
      end
      return row
    end
  end

  --- Return the first row matching a query, or nil if no rows match.
  --- Convenience method for single-row lookups.
  function db:query_one(sql: string, ...: any): {string:any}
    for row in self:query(sql, ...) do
      return row
    end
    return nil
  end

  --- Execute fn within a transaction. Calls BEGIN before fn, COMMIT after
  --- fn returns, and ROLLBACK if fn raises an error.
  --- Returns true on success, or false and an error message on failure.
  function db:transaction(fn: function(Database)): boolean, string
    local ok, err = self:exec("BEGIN IMMEDIATE")
    if not ok then
      return false, err or "begin failed"
    end
    local success, call_err = pcall(fn, self) as (boolean, string)
    if not success then
      self:exec("ROLLBACK")
      return false, call_err or "transaction failed"
    end
    return self:exec("COMMIT")
  end

  function db:last_insert_rowid(): number
    return raw_db:last_insert_rowid()
  end

  function db:changes(): number
    return raw_db:changes()
  end

  db.close = function(_: Database)
    if not closed then
      closed = true
      local _ = raw_db:close()
    end
  end

  return setmetatable(db, {
    __close = function(self: Database) self:close() end
  }) as Database
end

--- Open or create an SQLite database.
--- @param filename string Database path (use ":memory:" for in-memory)
--- @return Database Database handle with __close support
--- @return string Error message on failure
local function open(filename: string): Database, string
  local raw_db, errcode, errmsg = sqlite3.open(filename)
  if not raw_db then
    return nil, errmsg or ("error code " .. tostring(errcode))
  end
  return make_database(raw_db)
end

local record sqlite
  open: function(filename: string): Database, string
  Database: Database
  Statement: Statement
end

local M: sqlite = {
  open = open,
}

return M
