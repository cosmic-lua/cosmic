--- Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns.
--- Wraps lsqlite3 with proper error returns and resource management.
---
--- Prefer `db:exec()`, `db:query()`, `db:query_one()`, and
--- `db:transaction()` over manual preparation, binding, and stepping.
---
---     local sqlite = require("cosmic.sqlite")
---     local db = sqlite.open(":memory:")
---     db:exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
---     db:exec("INSERT INTO users (name) VALUES (?)", "alice")
---     for row in db:query("SELECT * FROM users WHERE name = ?", "alice") do
---       print(row.id, row.name)
---     end
---     db:close()
---
--- Binary values: wrap with `sqlite.blob(s)` to store with BLOB affinity
--- (a bare Lua string always binds as TEXT). Opening applies sensible
--- per-connection defaults — a 5000ms busy timeout, foreign_keys=ON,
--- and WAL journal mode with synchronous=NORMAL; each has an
--- `Options` field to tune or disable it.

local lsqlite3 = require("cosmo.lsqlite3")
local defaults_mod = require("cosmic.sqlite.defaults")
local stmt_cache_mod = require("cosmic.sqlite.stmt_cache")
local row_iter = require("cosmic.sqlite.row_iter")
local bind_mod = require("cosmic.sqlite.bind")
local params_mod = require("cosmic.sqlite.params")
local extras_mod = require("cosmic.sqlite.extras")

-- The raw lsqlite3 surface is fully typed since the 2026.07.13 pin;
-- the wrapper uses the generated types directly (no Raw* mirrors).
local sqlite3 = lsqlite3

--- Callable row iterator with an out-of-band error channel. Use it in a
--- `for row in ... do` loop, then call `:err()` afterward to detect a step
--- error (SQLITE_BUSY / CORRUPT / a RETURNING constraint failure) a for-loop
--- cannot observe inline. `:err()` is nil only on a clean SQLITE_DONE.
---
--- Draining the loop releases the underlying prepared statement. When
--- iteration may stop early, call `:close()` (idempotent), or declare the
--- iterator to-be-closed — `local rows <close> = db:query(...)` — so the
--- statement is released on scope exit; garbage collection is the backstop.
local record Rows
  metamethod __call: function(self: Rows): {string: any}
  metamethod __close: function(self: Rows)
  --- Step error from iteration, or nil after a clean SQLITE_DONE.
  err: function(self: Rows): string | nil
  --- Release the underlying prepared statement early idempotent.
  close: function(self: Rows)
end

--- Callable positional-value iterator, the `Statement:values()` counterpart
--- to `Rows`. Same `:err()` contract.
---
--- CAVEAT: a row whose FIRST column is SQL NULL returns `nil` as its first
--- (and, to Lua, only visible) value, which a `for ... in` generic-for loop
--- reads as end-of-iteration — the row is silently dropped, `:err()` stays
--- nil, and remaining rows are never stepped. This is inherent to Lua's
--- generic-for protocol (it stops at a nil first return) and the contract
--- cannot change without breaking `local a, b, c = iter()` positional
--- callers. Use `rows()` (or call the iterator directly, `local a, b, c =
--- iter()`, one row at a time) when column 1 may be NULL.
local record Values
  metamethod __call: function(self: Values): any ...
  metamethod __close: function(self: Values)
  --- Step error from iteration, or nil after a clean SQLITE_DONE.
  err: function(self: Values): string | nil
  --- End iteration early (idempotent); also runs on scope exit via
  --- to-be-closed. Does not finalize the owning Statement — that is
  --- Statement:close()'s job, since the Statement may be reused.
  close: function(self: Values)
end

--- Statement handle with automatic cleanup.
local record Statement
  --- Bind parameters by position (resets the statement first). Handles
  --- trailing nils; `sqlite.blob()` wrappers bind with BLOB affinity.
  bind: function(self: Statement, ...: any): boolean, string
  --- Bind positional parameters from a list; the count comes from the
  --- SQL, so nil holes in the table bind as NULL.
  bind_list: function(self: Statement, values: {any}): boolean, string
  --- Bind :name placeholders from a key/value table (keys without the
  --- colon). `sqlite.blob()` wrappers are rejected — use positional
  --- binding for blobs.
  bind_named: function(self: Statement, params: {string: any}): boolean, string
  --- Callable iterator over result rows as {column: value} tables;
  --- check `:err()` after the loop for step errors.
  rows: function(self: Statement): Rows
  --- Callable iterator yielding each row's column values positionally;
  --- same `:err()` contract as rows(). CAVEAT: a NULL first column ends a
  --- `for` loop over this early (see Values above) -- prefer rows() when
  --- column 1 may be NULL.
  values: function(self: Statement): Values
  --- Step the statement to completion (for INSERT/UPDATE/DDL).
  exec: function(self: Statement): boolean, string
  --- Reset for re-execution; existing bindings are kept.
  reset: function(self: Statement)
  --- Number of result columns.
  columns: function(self: Statement): integer
  --- Name of result column n (1-indexed).
  column_name: function(self: Statement, n: integer): string
  --- Finalize the statement (idempotent); also runs on scope exit via
  --- to-be-closed.
  close: function(self: Statement)
end

--- Database handle with automatic cleanup.
local record Database
  --- Compile sql into a reusable Statement for manual bind/iterate;
  --- prefer query()/exec() unless you need statement reuse.
  prepare: function(self: Database, sql: string): Statement | nil, string
  --- Run sql with positional `?` parameters and iterate result rows as
  --- {column: value} tables: `for row in db:query(...) do ... end`.
  --- Statements are cached per connection. Check `:err()` after the
  --- loop (or use `<close>`) per the Rows contract.
  query: function(self: Database, sql: string, ...: any): Rows | nil, string
  --- query() with parameters in a list, so nil holes bind as NULL.
  query_list: function(self: Database, sql: string, values: {any}): Rows | nil, string
  --- query() with :name placeholders bound from a key/value table.
  query_named: function(self: Database, sql: string, params: {string: any}): Rows | nil, string
  --- First matching row, or nil (with no error) when no row matches.
  --- The statement is always finalized, even when rows remain.
  query_one: function(self: Database, sql: string, ...: any): {string: any} | nil, string
  --- First column of the first row (nil + no error when no row matches
  --- or the value is SQL NULL); see cosmic.sqlite.extras.
  query_value: function(self: Database, sql: string, ...: any): any, string
  --- Execute sql with positional `?` parameters; use for statements
  --- that return no rows (INSERT/UPDATE/DELETE/DDL). Multi-statement
  --- sql runs only in the no-parameter form; with parameters it is
  --- REJECTED (sqlite would silently run just the first statement).
  exec: function(self: Database, sql: string, ...: any): boolean, string
  --- exec() with parameters in a list, so nil holes bind as NULL.
  exec_list: function(self: Database, sql: string, values: {any}): boolean, string
  --- exec() with :name placeholders bound from a key/value table.
  exec_named: function(self: Database, sql: string, params: {string: any}): boolean, string
  --- Run fn inside BEGIN IMMEDIATE .. COMMIT. Rolls back when fn
  --- raises, returns false, or returns nil plus an error; returning
  --- nothing (or true) commits. The callback is typed variadic
  --- (Teal cannot express optional returns), so a typed
  --- `function(db): boolean` rollback needs no cast; see
  --- cosmic.sqlite.extras.
  transaction: function(self: Database, fn: function(Database): any ...): boolean, string
  --- Run fn in a nestable savepoint with transaction's rollback rules;
  --- see cosmic.sqlite.extras.
  savepoint: function(self: Database, fn: function(Database): any ...): boolean, string
  --- rowid of the most recent successful INSERT (0 if closed).
  last_insert_rowid: function(self: Database): integer
  --- Rows modified by the most recent INSERT/UPDATE/DELETE (0 if closed).
  changes: function(self: Database): integer
  --- Close the database and its cached statements (idempotent); also
  --- runs on scope exit via to-be-closed. Live user-prepared
  --- Statements do not block it: the binding finalizes them during
  --- close. Returns false plus sqlite's message if the raw close ever
  --- fails — the handle is NOT marked closed then, so the database
  --- stays usable and a retry is a real retry, not a stale-flag
  --- success.
  close: function(self: Database): boolean, string
end

-- Statement:rows() release callback: a Statement outlives its iterators
-- (it may be reused via reset()+bind() after the Rows is done), so
-- releasing must only end iteration, never finalize the raw statement.
-- Statement:close() (or its own <close>/__close/gc) owns finalization.
local function keep_statement_open(_: lsqlite3.Statement) end

local function make_statement(raw_stmt: lsqlite3.Statement, raw_db: lsqlite3.Database): Statement
  local stmt: Statement = {}
  local closed = false

  --- Bind parameters by position. Handles trailing nil values correctly
  --- (unlike varargs with table.unpack which drops them).
  --- Values wrapped with `sqlite.blob()` are bound with BLOB affinity.
  function stmt:bind(...: any): boolean, string
    raw_stmt:reset()
    local n = select("#", ...)
    for i = 1, n do
      local val = select(i, ...)
      local rc = bind_mod.bind_at(raw_stmt, i, val)
      if rc ~= sqlite3.OK then
        return false, raw_db:errmsg()
      end
    end
    return true
  end

  --- Bind parameters from a list table. The count is derived from the SQL,
  --- so nil values in the table are handled correctly without an explicit count.
  --- Values wrapped with `sqlite.blob()` are bound with BLOB affinity.
  function stmt:bind_list(values: {any}): boolean, string
    raw_stmt:reset()
    local count = raw_stmt:bind_parameter_count()
    for i = 1, count do
      local rc = bind_mod.bind_at(raw_stmt, i, values[i])
      if rc ~= sqlite3.OK then
        return false, raw_db:errmsg()
      end
    end
    return true
  end

  --- Bind named parameters from a key/value table.
  --- SQL should use :name placeholders (e.g. ":foo", ":bar").
  --- Table keys are names without the colon prefix.
  --- `sqlite.blob()` wrappers are not supported here: the underlying
  --- bind_names call binds the wrapper table itself, silently losing BLOB
  --- affinity, so they are rejected — use positional binding for blobs.
  function stmt:bind_named(params: {string: any}): boolean, string
    raw_stmt:reset()
    for name, v in pairs(params) do
      if bind_mod.is_blob(v) then
        return false, "blob value for :" .. name .. " requires positional binding"
      end
    end
    local rc = raw_stmt:bind_names(params)
    if rc ~= sqlite3.OK then
      return false, raw_db:errmsg()
    end
    return true
  end

  function stmt:rows(): Rows
    -- Shares row_iter's iteration body (column-name resolution, step,
    -- error surfacing) instead of a second copy; on_close ends iteration
    -- without finalizing, since this Statement may still be reused.
    local iter = row_iter.make(raw_stmt, raw_db, keep_statement_open, sqlite3.ROW, sqlite3.DONE)
    return iter as Rows -- cast: row_iter record to public Rows
  end

  -- CAVEAT (see Values above): a `for ... in` loop over this iterator ends
  -- the moment column 1 comes back NULL, because that's Lua's own signal
  -- for end-of-iteration. rows() doesn't have this hazard; calling the
  -- iterator directly one row at a time (`local a, b, c = iter()`) does.
  function stmt:values(): Values
    local step_err: string
    local done = false
    local col_count = raw_stmt:columns()

    local iter = setmetatable({} as Values, { -- cast: empty table into callable record
        __call = function(_: Values): any ...
          if done then
            return nil
          end
          local rc = raw_stmt:step()
          if rc == sqlite3.ROW then
            local vals: {integer: any} = {}
            for idx = 0, col_count - 1 do
              vals[idx + 1] = raw_stmt:get_value(idx)
            end
            -- Bound the unpack: a NULL first column leaves vals[1] == nil,
            -- and an unbounded unpack would drop the remaining columns.
            return table.unpack(vals, 1, col_count)
          end
          if rc ~= sqlite3.DONE then
            step_err = raw_db:errmsg()
          end
          done = true
          return nil
        end,
        __close = function(self: Values) self:close() end,
      })
    iter.err = function(_: Values): string | nil return step_err end
    iter.close = function(_: Values) done = true end
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

  stmt.columns = function(_: Statement): integer
    return raw_stmt:columns()
  end

  stmt.column_name = function(_: Statement, n: integer): string
    return raw_stmt:get_name(n - 1)
  end

  stmt.close = function(_: Statement)
    if closed then return end
    closed = true
    -- The binding finalizes outstanding statements when the DATABASE
    -- closes; finalize on such a dead vm throws. Guard so close (and
    -- the __gc/__close paths that reach it) never raises.
    if raw_stmt:isopen() then
      local _ = raw_stmt:finalize()
    end
  end

  -- __gc is the backstop for an abandoned user Statement, matching the
  -- Rows iterator: without it a dropped db:prepare() handle leaks its
  -- raw statement — the very SQLITE_BUSY that makes db:close() fail.
  return setmetatable(stmt, {
      __close = function(self: Statement) self:close() end,
      __gc = function(self: Statement) self:close() end,
    })
end

local function make_database(raw_db: lsqlite3.Database): Database
  local db: Database = {}
  local closed = false

  -- Reuses prepared statements for db:exec (see cosmic.sqlite.stmt_cache).
  local stmt_cache = stmt_cache_mod.new(raw_db, sqlite3.OK, sqlite3.DONE, sqlite3.ROW, sqlite3.SCHEMA)

  function db:prepare(sql: string): Statement | nil, string
    if closed then
      return nil, "database is closed"
    end
    local raw_stmt = raw_db:prepare(sql)
    if not raw_stmt then
      return nil, raw_db:errmsg()
    end
    return make_statement(raw_stmt, raw_db)
  end

  function db:query(sql: string, ...: any): Rows | nil, string
    if closed then
      return nil, "query failed: database is closed"
    end
    local raw_stmt, on_close, err = stmt_cache:checkout(sql)
    if not raw_stmt then
      return nil, "query failed: " .. (err or "unknown error")
    end
    -- Hot path: skip the full Statement object and its per-call closures;
    -- bind and iterate the raw statement directly (see cosmic.sqlite.row_iter).
    local iter, bind_err = row_iter.query(
      raw_stmt, raw_db, on_close,
      sqlite3.OK, sqlite3.ROW, sqlite3.DONE, ...)
    if not iter then
      return nil, bind_err
    end
    return iter as Rows -- cast: row_iter record to public Rows
  end

  function db:exec(sql: string, ...: any): boolean, string
    if closed then
      return false, "database is closed"
    end
    local n = select("#", ...)
    if n == 0 then
      -- no params: use raw exec (faster for DDL)
      local rc = raw_db:exec(sql)
      if rc ~= sqlite3.OK then
        return false, raw_db:errmsg()
      end
      return true
    end

    -- has params: reuse a cached prepared statement (see cosmic.sqlite.stmt_cache)
    local args: {integer: any} = {}
    for i = 1, n do
      args[i] = select(i, ...)
    end
    return stmt_cache:exec(sql, args, n)
  end

  -- exec_list, exec_named, query_list, query_named live in
  -- cosmic.sqlite.params (same prepare/bind/consume shape, split out to
  -- keep this file under the 500-line cap); query_value, transaction
  -- and savepoint live in cosmic.sqlite.extras for the same reason.
  params_mod.attach(db)
  extras_mod.attach(db)

  --- Return the first row matching a query, or nil if no rows match.
  --- Convenience method for single-row lookups.
  --- The underlying prepared statement is always finalized before returning,
  --- even when only the first row is consumed, preventing statement leaks.
  function db:query_one(sql: string, ...: any): {string: any} | nil, string
    local iter, err = self:query(sql, ...)
    if not iter then
      return nil, err
    end
    local it = iter
    -- Capture the first row, then close the iterator so the statement is
    -- released deterministically without stepping the remaining rows.
    local first: {string: any} = nil
    for row in it do
      first = row
      break
    end
    it:close()
    -- Surface a step error rather than a partial row that looks clean.
    local step_err = it:err()
    if step_err then
      return nil, step_err
    end
    return first
  end

  function db:last_insert_rowid(): integer
    if closed then
      return 0
    end
    return raw_db:last_insert_rowid()
  end

  function db:changes(): integer
    if closed then
      return 0
    end
    return raw_db:changes()
  end

  db.close = function(_: Database): boolean, string
    if closed then
      return true
    end
    -- Mark closed only AFTER the raw close succeeds: marking first
    -- made a failed close unrecoverable — the retry hit the guard
    -- above and reported success while sqlite's handle stayed open.
    -- (lsqlite3 finalizes outstanding statements itself, so a failure
    -- here is defensive rather than reachable today.) close_all is
    -- idempotent (it clears as it finalizes), so a retry re-runs it
    -- harmlessly.
    stmt_cache:close_all()
    local rc = raw_db:close()
    if rc ~= sqlite3.OK then
      return false, raw_db:errmsg()
    end
    closed = true
    return true
  end

  return setmetatable(db, {
      __close = function(self: Database) local _ok, _err = self:close() end
    })
end

--- Options for opening a database (see cosmic.sqlite.defaults).
local type Options = defaults_mod.Options

--- Open or create an SQLite database.
--- Relative paths are resolved against the current working directory.
--- Absolute paths (e.g. "/var/data/app.db") work as expected.
--- Use ":memory:" for an in-memory database that is not written to disk.
--- The file is created if it does not already exist (unless read_only).
--- Opening applies cosmic's per-connection defaults: a 5000ms busy
--- timeout so concurrent processes wait for each other instead of
--- failing instantly with SQLITE_BUSY, foreign_keys=ON, and — for
--- writable connections — WAL journal mode with synchronous=NORMAL.
--- Each default has an Options field to tune or disable it.
--- @param filename string Database path (use ":memory:" for in-memory)
--- @param opts Options? busy_timeout_ms, read_only, foreign_keys, wal
--- @return Database | nil Database handle with __close support
--- @return string Error message on failure
local function open(filename: string, opts?: Options): Database | nil, string
  local raw_db: lsqlite3.Database | nil
  local errcode: number | nil
  local errmsg: string | nil
  if opts and opts.read_only then
    raw_db, errcode, errmsg = sqlite3.open(filename, sqlite3.OPEN_READONLY)
  else
    raw_db, errcode, errmsg = sqlite3.open(filename)
  end
  -- `is` narrows in the positive branch (early-exit guards don't);
  -- safe at this cosmo.* boundary because the cosmic searcher is the
  -- only loader cosmic installs.
  if raw_db is lsqlite3.Database then
    local ok, derr = defaults_mod.apply(raw_db, opts)
    if not ok then
      raw_db:close()
      return nil, derr
    end
    return make_database(raw_db)
  end
  return nil, errmsg or ("error code " .. tostring(errcode))
end

local record sqlite
  type Blob = bind_mod.Blob
  type Options = Options
  --- Exported so callers can name the handles open() and its methods
  --- return; these are type aliases, not runtime values. A
  --- `Database: Database` field spelling would declare phantom fields
  --- that are nil at runtime.
  type Database = Database
  type Statement = Statement
  type Rows = Rows
  type Values = Values

  open: function(filename: string, opts?: Options): Database | nil, string
  blob: function(data: string): bind_mod.Blob
end

local M: sqlite = {
  open = open,
  blob = bind_mod.blob,
}

return M
