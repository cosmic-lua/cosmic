--- Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns.
--- Wraps lsqlite3 with proper error returns and resource management.
---
--- This module provides a high-level API over lsqlite3. Prefer
--- `db:exec()`, `db:query()`, `db:query_one()`, and `db:transaction()`
--- over manual statement preparation, binding, and stepping.
--- The underlying lsqlite3 bindings are used internally; prefer the
--- high-level API shown below.
---
---     local sqlite = require("cosmic.sqlite")
---     local db = sqlite.open(":memory:")
---     db:exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
---     db:exec("INSERT INTO users (name) VALUES (?)", "alice")
---     for row in db:query("SELECT * FROM users WHERE name = ?", "alice") do
---       print(row.id, row.name)
---     end
---     db:close()

local lsqlite3 = require("cosmo.lsqlite3")
local stmt_cache_mod = require("cosmic.sqlite_stmt_cache")
local row_iter = require("cosmic.sqlite_row_iter")

-- Raw lsqlite3 types (0-indexed, requires manual cleanup)
local record RawStatement
  bind_values: function(self: RawStatement, ...: any): number
  bind: function(self: RawStatement, n: number, value?: any): number
  bind_names: function(self: RawStatement, params: {string: any}): number
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
  SCHEMA: number
  open: function(filename: string): RawDatabase, number, string
end

local sqlite3 = lsqlite3 as RawSqlite3

--- Callable row iterator with an out-of-band error channel. Use it in a
--- generic `for row in ... do` loop, then call `:err()` afterward to detect
--- a step error (SQLITE_BUSY / CORRUPT / a RETURNING constraint failure)
--- that a for-loop cannot observe inline. `:err()` is nil only when
--- iteration reached SQLITE_DONE cleanly.
local record Rows
  metamethod __call: function(self: Rows): {string: any}
  err: function(self: Rows): string
end

--- Callable positional-value iterator, the `Statement:values()` counterpart
--- to `Rows`. Same `:err()` contract.
local record Values
  metamethod __call: function(self: Values): any ...
  err: function(self: Values): string
end

--- Statement handle with automatic cleanup.
local record Statement
  bind: function(self: Statement, ...: any): boolean, string
  bind_list: function(self: Statement, values: {any}): boolean, string
  bind_named: function(self: Statement, params: {string: any}): boolean, string
  rows: function(self: Statement): Rows
  values: function(self: Statement): Values
  exec: function(self: Statement): boolean, string
  reset: function(self: Statement)
  columns: function(self: Statement): number
  column_name: function(self: Statement, n: number): string
  close: function(self: Statement)
end

--- Database handle with automatic cleanup.
local record Database
  prepare: function(self: Database, sql: string): Statement, string
  query: function(self: Database, sql: string, ...: any): Rows, string
  query_list: function(self: Database, sql: string, values: {any}): Rows, string
  query_named: function(self: Database, sql: string, params: {string: any}): Rows, string
  query_one: function(self: Database, sql: string, ...: any): {string: any}, string
  exec: function(self: Database, sql: string, ...: any): boolean, string
  exec_list: function(self: Database, sql: string, values: {any}): boolean, string
  exec_named: function(self: Database, sql: string, params: {string: any}): boolean, string
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
  function stmt:bind_named(params: {string: any}): boolean, string
    raw_stmt:reset()
    local rc = raw_stmt:bind_names(params)
    if rc ~= sqlite3.OK then
      return false, raw_db:errmsg()
    end
    return true
  end

  function stmt:rows(): Rows
    local step_err: string
    local col_count = raw_stmt:columns()
    local col_names: {integer: string}
    local first_call = true

    local iter = setmetatable({} as Rows, {
        __call = function(_: Rows): {string: any}
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
            local row: {string: any} = {}
            for idx = 0, col_count - 1 do
              local name = col_names[(idx + 1) as integer]
              row[name] = raw_stmt:get_value(idx)
            end
            return row
          end
          -- Only SQLITE_DONE is a clean end; surface anything else.
          if rc ~= sqlite3.DONE then
            step_err = raw_db:errmsg()
          end
          return nil
        end,
      })
    iter.err = function(_: Rows): string return step_err end
    return iter
  end

  function stmt:values(): Values
    local step_err: string
    local col_count = raw_stmt:columns() as integer

    local iter = setmetatable({} as Values, {
        __call = function(_: Values): any ...
          local rc = raw_stmt:step()
          if rc == sqlite3.ROW then
            local vals: {integer: any} = {}
            for idx = 0, col_count - 1 do
              vals[(idx + 1) as integer] = raw_stmt:get_value(idx)
            end
            -- Bound the unpack: a NULL first column leaves vals[1] == nil,
            -- and an unbounded unpack would drop the remaining columns.
            return table.unpack(vals, 1, col_count)
          end
          if rc ~= sqlite3.DONE then
            step_err = raw_db:errmsg()
          end
          return nil
        end,
      })
    iter.err = function(_: Values): string return step_err end
    return iter
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
    if closed then return end
    closed = true
    local _ = raw_stmt:finalize()
  end

  return setmetatable(stmt, {
      __close = function(self: Statement) self:close() end
    }) as Statement
end

-- Wrap a prepared+bound statement's row iterator: finalize the statement
-- when iteration ends and forward the step error through `:err()`.
local function make_query_iter(stmt: Statement): Rows
  local raw_iter = stmt:rows()
  local done = false
  local iter = setmetatable({} as Rows, {
      __call = function(_: Rows): {string: any}
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
      end,
    })
  iter.err = function(_: Rows): string return raw_iter:err() end
  return iter
end

local function make_database(raw_db: RawDatabase): Database
  local db: Database = {}
  local closed = false

  -- Reuses prepared statements for db:exec (see cosmic.sqlite_stmt_cache).
  local stmt_cache = stmt_cache_mod.new(raw_db as any, sqlite3.OK, sqlite3.DONE, sqlite3.ROW, sqlite3.SCHEMA)

  function db:prepare(sql: string): Statement, string
    if closed then
      return nil, "database is closed"
    end
    local raw_stmt, errcode, errmsg = raw_db:prepare(sql)
    if not raw_stmt then
      return nil, errmsg or ("error code " .. tostring(errcode))
    end
    return make_statement(raw_stmt, raw_db)
  end

  function db:query(sql: string, ...: any): Rows, string
    if closed then
      return nil, "query failed: database is closed"
    end
    local raw_stmt, on_close, err = stmt_cache:checkout(sql)
    if not raw_stmt then
      return nil, "query failed: " .. (err or "unknown error")
    end
    -- Hot path: skip the full Statement object and its per-call closures;
    -- bind and iterate the raw statement directly (see cosmic.sqlite_row_iter).
    local iter, bind_err = row_iter.query(
      raw_stmt as any, raw_db as any, on_close as any,
      sqlite3.OK, sqlite3.ROW, sqlite3.DONE, ...)
    if not iter then
      return nil, bind_err
    end
    return iter as Rows
  end

  function db:exec(sql: string, ...: any): boolean, string
    if closed then
      return false, "database is closed"
    end
    local n = select("#", ...) as integer
    if n == 0 then
      -- no params: use raw exec (faster for DDL)
      local rc = raw_db:exec(sql)
      if rc ~= sqlite3.OK then
        return false, raw_db:errmsg()
      end
      return true
    end

    -- has params: reuse a cached prepared statement (see cosmic.sqlite_stmt_cache)
    local args: {integer: any} = {}
    for i = 1, n do
      args[i] = select(i, ...)
    end
    return stmt_cache:exec(sql, args, n)
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
  function db:exec_named(sql: string, params: {string: any}): boolean, string
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
  function db:query_list(sql: string, values: {any}): Rows, string
    local stmt, err = self:prepare(sql)
    if not stmt then
      return nil, "query failed: " .. (err or "unknown error")
    end

    local ok, bind_err = stmt:bind_list(values)
    if not ok then
      stmt:close()
      return nil, "bind failed: " .. (bind_err or "unknown error")
    end

    return make_query_iter(stmt)
  end

  --- Query with named parameters.
  --- SQL should use :name placeholders. Table keys are names without the colon.
  function db:query_named(sql: string, params: {string: any}): Rows, string
    local stmt, err = self:prepare(sql)
    if not stmt then
      return nil, "query failed: " .. (err or "unknown error")
    end

    local ok, bind_err = stmt:bind_named(params)
    if not ok then
      stmt:close()
      return nil, "bind failed: " .. (bind_err or "unknown error")
    end

    return make_query_iter(stmt)
  end

  --- Return the first row matching a query, or nil if no rows match.
  --- Convenience method for single-row lookups.
  --- The underlying prepared statement is always finalized before returning,
  --- even when only the first row is consumed, preventing statement leaks.
  function db:query_one(sql: string, ...: any): {string: any}, string
    local iter, err = self:query(sql, ...)
    if not iter then
      return nil, err
    end
    -- Capture the first row, then drain the iterator so the statement is
    -- finalized deterministically (returning early from a for-loop leaves
    -- the iterator open and the prepared statement unfinalized until GC).
    local first: {string: any} = nil
    for row in iter do
      first = row
      break
    end
    -- Drain remaining rows so the wrapping closure calls stmt:close().
    if first ~= nil then
      while iter() ~= nil do end
    end
    -- Surface a step error rather than a partial row that looks clean.
    local step_err = iter:err()
    if step_err then
      return nil, step_err
    end
    return first
  end

  --- Execute fn within a transaction. BEGIN before fn; COMMIT if fn returns
  --- cleanly; ROLLBACK if fn raises OR signals failure the library way -- a
  --- returned `false`, or `nil` plus an error (nothing returned still commits).
  function db:transaction(fn: function(Database)): boolean, string
    local ok, err = self:exec("BEGIN IMMEDIATE")
    if not ok then
      return false, err or "begin failed"
    end
    local success, result, result_err = pcall(fn, self) as(boolean, any, any)
    if not success then
      self:exec("ROLLBACK")
      return false, (result as string) or "transaction failed"
    end
    if result == false or (result == nil and result_err ~= nil) then
      self:exec("ROLLBACK")
      return false, (result_err as string) or "transaction rolled back"
    end
    return self:exec("COMMIT")
  end

  function db:last_insert_rowid(): number
    if closed then
      return 0
    end
    return raw_db:last_insert_rowid()
  end

  function db:changes(): number
    if closed then
      return 0
    end
    return raw_db:changes()
  end

  db.close = function(_: Database)
    if not closed then
      closed = true
      stmt_cache:close_all()
      local _ = raw_db:close()
    end
  end

  return setmetatable(db, {
      __close = function(self: Database) self:close() end
    }) as Database
end

--- Open or create an SQLite database.
--- Relative paths are resolved against the current working directory.
--- Absolute paths (e.g. "/var/data/app.db") work as expected.
--- Use ":memory:" for an in-memory database that is not written to disk.
--- The file is created if it does not already exist.
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
