--- Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns.
--- Wraps lsqlite3 with proper error returns and resource management.
---
--- Prefer `db:exec()`, `db:query()`, `db:query_one()`, and
--- `db:transaction()` over manual preparation, binding, and stepping.
--- A scalar lookup is `db:query_one()` too — name the column and read
--- it (`db:query_one("SELECT COUNT(*) AS n FROM t").n`). There is no
--- separate `query_value` shortcut: a `found` flag cannot fit beside a
--- value and an error in two slots, and without it a NULL column and a
--- missing row read the same.
--- Parameters travel in one table: a list binds `?` placeholders
--- positionally, a keyed table binds `:name` placeholders.
---
--- ```teal
--- local sqlite = require("cosmic.sqlite")
--- local db = assert(sqlite.open(":memory:"))
--- assert(db:exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"))
--- assert(db:exec("INSERT INTO users (name) VALUES (?)", {"alice"}))
--- for row in assert(db:query("SELECT * FROM users WHERE name = :n", {n = "alice"})) do
---   print(row.id, row.name)
--- end
--- assert(db:close())
--- ```
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
local column_mod = require("cosmic.sqlite.column")
local extras_mod = require("cosmic.sqlite.extras")

-- The raw lsqlite3 surface is fully typed since the 2026.07.13 pin;
-- the wrapper uses the generated types directly (no Raw* mirrors).
local sqlite3 = lsqlite3

--- One parameter table for query/exec: a list binds `?` placeholders
--- positionally, a keyed table binds `:name` placeholders (see
--- cosmic.sqlite.bind).
local type Params = bind_mod.Params

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
  --- Release the underlying prepared statement early (idempotent; a
  --- second call returns true). Reports a finalize failure instead of
  --- swallowing it.
  close: function(self: Rows): boolean, string
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
  --- colon). `sqlite.blob()` wrappers bind with BLOB affinity, same as
  --- positional binding; a name missing from the table binds as NULL.
  bind_named: function(self: Statement, params: {string: any}): boolean, string
  --- Callable iterator over result rows as {column: value} tables;
  --- check `:err()` after the loop for step errors.
  rows: function(self: Statement): Rows
  --- Step the statement to completion (for INSERT/UPDATE/DDL).
  exec: function(self: Statement): boolean, string
  --- Reset for re-execution; existing bindings are kept.
  reset: function(self: Statement)
  --- Number of result columns.
  columns: function(self: Statement): integer
  --- Name of result column n (1-indexed).
  column_name: function(self: Statement, n: integer): string
  --- Finalize the statement (idempotent; a second call returns true);
  --- also runs on scope exit via to-be-closed. Reports a finalize
  --- failure instead of swallowing it.
  close: function(self: Statement): boolean, string
end

--- Database handle with automatic cleanup.
local record Database
  --- Compile sql into a reusable Statement for manual bind/iterate;
  --- prefer query()/exec() unless you need statement reuse.
  prepare: function(self: Database, sql: string): Statement | nil, string
  --- Run sql and iterate result rows as {column: value} tables:
  --- `for row in db:query(...) do ... end`. params is one table: a
  --- list binds `?` placeholders positionally (nil holes bind NULL), a
  --- keyed table binds `:name` placeholders. Statements are cached per
  --- connection. Check `:err()` after the loop (or use `<close>`) per
  --- the Rows contract.
  query: function(self: Database, sql: string, params?: Params): Rows | nil, string
  --- First matching row. `nil, nil` means NO ROW MATCHED — an ordinary
  --- empty result, not a failure — so `check.must(db:query_one(...))`
  --- throws on it; guard with `if row then` instead. `nil, err` is a
  --- real failure. The statement is always finalized, even when rows
  --- remain.
  query_one: function(self: Database, sql: string, params?: Params): {string: any} | nil, string
  --- Execute one statement that returns no rows (INSERT/UPDATE/DELETE/
  --- DDL), with the same one-table params as query(). Statements are
  --- cached per connection. Multi-statement sql is REJECTED here
  --- (sqlite would silently run just the first statement) — run a
  --- parameterless script with exec_script().
  exec: function(self: Database, sql: string, params?: Params): boolean, string
  --- Run a multi-statement SQL script (no parameters, no result rows):
  --- schema setup, migrations, PRAGMA batches. The one method that
  --- executes more than one statement per call.
  exec_script: function(self: Database, sql: string): boolean, string
  --- Run fn inside BEGIN IMMEDIATE .. COMMIT, with an explicit
  --- verdict: `return true` commits, `return false, why` rolls back,
  --- and a raise rolls back. Any other return also rolls back — with
  --- an error naming the contract — so a callback that forgets its
  --- verdict cannot commit by accident; see cosmic.sqlite.extras.
  transaction: function(self: Database, fn: function(Database): boolean, string): boolean, string
  --- Run fn in a nestable savepoint with transaction's verdict rules;
  --- see cosmic.sqlite.extras.
  savepoint: function(self: Database, fn: function(Database): boolean, string): boolean, string
  --- rowid of the most recent successful INSERT; nil + error once the
  --- database is closed (0 is a legitimate live value, so it cannot
  --- double as the closed marker).
  last_insert_rowid: function(self: Database): integer | nil, string
  --- Rows modified by the most recent INSERT/UPDATE/DELETE; nil + error
  --- once the database is closed.
  changes: function(self: Database): integer | nil, string
  --- Close the database and its cached statements (idempotent); also
  --- runs on scope exit via to-be-closed. Live user-prepared
  --- Statements do not block it: the binding finalizes them during
  --- close. Returns false plus sqlite's message if the raw close ever
  --- fails — the handle is NOT marked closed then, so the database
  --- stays usable and a retry is a real retry, not a stale-flag
  --- success. Like every other fallible Database method it returns
  --- `boolean, string`, so the result must be captured —
  --- `assert(db:close())`, or `local _ok, _err = db:close()` for a
  --- deliberate fire-and-forget.
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
  --- Table keys are names without the colon prefix. Values route
  --- through the shared bind step, so `sqlite.blob()` wrappers bind
  --- with BLOB affinity here too.
  function stmt:bind_named(params: {string: any}): boolean, string
    raw_stmt:reset()
    local rc = bind_mod.bind_named(raw_stmt, sqlite3.OK, params)
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

  stmt.close = function(_: Statement): boolean, string
    if closed then return true end
    closed = true
    -- The binding finalizes outstanding statements when the DATABASE
    -- closes; finalize on such a dead vm throws. Guard so close (and
    -- the __gc/__close paths that reach it) never raises.
    if raw_stmt:isopen() then
      local rc = raw_stmt:finalize()
      if rc ~= sqlite3.OK then
        return false, raw_db:errmsg()
      end
    end
    return true
  end

  -- __gc is the backstop for an abandoned user Statement, matching the
  -- Rows iterator: without it a dropped db:prepare() handle leaks its
  -- raw statement — the very SQLITE_BUSY that makes db:close() fail.
  return setmetatable(stmt, {
      __close = function(self: Statement) local _ok, _err = self:close() end,
      __gc = function(self: Statement) local _ok, _err = self:close() end,
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

  function db:query(sql: string, params?: Params): Rows | nil, string
    if closed then
      return nil, "query failed: database is closed"
    end
    local co, err = stmt_cache:checkout(sql)
    if not co then
      return nil, "query failed: " .. (err or "unknown error")
    end
    -- Hot path: skip the full Statement object and its per-call closures;
    -- bind and iterate the raw statement directly (see cosmic.sqlite.row_iter).
    local iter, bind_err = row_iter.query(
      co.stmt, raw_db, co.on_close,
      sqlite3.OK, sqlite3.ROW, sqlite3.DONE, params)
    if not iter then
      return nil, bind_err
    end
    return iter as Rows -- cast: row_iter record to public Rows
  end

  function db:exec(sql: string, params?: Params): boolean, string
    if closed then
      return false, "database is closed"
    end
    -- Always through the statement cache: repeated calls with the same
    -- SQL reuse the prepared statement, and the cache rejects
    -- multi-statement sql on the miss path (exec_script is the
    -- explicit multi-statement method).
    return stmt_cache:exec(sql, params)
  end

  --- Run a multi-statement script. No parameters and no result rows:
  --- this is sqlite's raw exec, which runs every statement in the
  --- string — the capability exec() deliberately does not have.
  function db:exec_script(sql: string): boolean, string
    if closed then
      return false, "database is closed"
    end
    local rc = raw_db:exec(sql)
    if rc ~= sqlite3.OK then
      return false, raw_db:errmsg()
    end
    return true
  end

  -- query_value, transaction and savepoint live in
  -- cosmic.sqlite.extras (same attach shape, split out to keep this
  -- file under the 500-line cap).
  extras_mod.attach(db)

  --- Return the first row matching a query, or nil if no rows match.
  --- Convenience method for single-row lookups.
  --- The underlying prepared statement is always finalized before returning,
  --- even when only the first row is consumed, preventing statement leaks.
  function db:query_one(sql: string, params?: Params): {string: any} | nil, string
    local iter, err = self:query(sql, params)
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
    local _cok, _cerr = it:close()
    -- Surface a step error rather than a partial row that looks clean.
    local step_err = it:err()
    if step_err then
      return nil, step_err
    end
    return first
  end

  function db:last_insert_rowid(): integer | nil, string
    if closed then
      return nil, "database is closed"
    end
    return raw_db:last_insert_rowid()
  end

  function db:changes(): integer | nil, string
    if closed then
      return nil, "database is closed"
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
  -- `is` narrows the guarded variable, here in the positive branch;
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
  type Params = Params
  --- Exported so callers can name the handles open() and its methods
  --- return; these are type aliases, not runtime values. A
  --- `Database: Database` field spelling would declare phantom fields
  --- that are nil at runtime.
  type Database = Database
  type Statement = Statement
  type Rows = Rows

  open: function(filename: string, opts?: Options): Database | nil, string
  blob: function(data: string): bind_mod.Blob

  --- Typed column readers over a row. A row is `{string: any}`, so
  --- reading a column whose type the caller knows costs a cast at every
  --- read; these move that check into one place that reports a mismatch
  --- instead of asserting one. `column_` prefixes them because `blob`
  --- above is already the BLOB constructor.
  column_text: function(row: {string: any}, column: string): string | nil, string
  column_number: function(row: {string: any}, column: string): number | nil, string
  column_integer: function(row: {string: any}, column: string): integer | nil, string
end

local M: sqlite = {
  open = open,
  blob = bind_mod.blob,
  column_text = column_mod.column_text,
  column_number = column_mod.column_number,
  column_integer = column_mod.column_integer,
}

return M
