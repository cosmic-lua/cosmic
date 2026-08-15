--- Internal helper for cosmic.sqlite: the per-connection defaults
--- sqlite.open() applies and the Options record that tunes them.
--- Lives in its own file so cosmic/sqlite/init.tl stays under the
--- 500-line cap.

local lsqlite3 = require("cosmo.lsqlite3")

--- Options for opening a database.
local record Options
  --- Busy timeout in milliseconds (default 5000). When another connection
  --- holds a conflicting lock, statements wait up to this long before
  --- failing with SQLITE_BUSY. Pass 0 to fail immediately (SQLite's raw
  --- default).
  busy_timeout_ms: integer
  --- Open the database read-only (default false). The file must exist.
  read_only: boolean
  --- Enforce FOREIGN KEY constraints (default true). SQLite's raw
  --- default ignores them, allowing dangling references; set false to
  --- restore that default.
  foreign_keys: boolean
  --- Use write-ahead logging with synchronous=NORMAL (default true).
  --- WAL makes writes faster and lets readers proceed alongside a
  --- writer; synchronous=NORMAL keeps WAL transactions safe from
  --- corruption while skipping redundant fsyncs. Set false to keep
  --- SQLite's raw defaults (rollback journal, synchronous=FULL). Never
  --- applied to read-only connections; a no-op for in-memory databases.
  --- Note WAL mode persists in the database file once set.
  wal: boolean
end

--- Apply cosmic's per-connection defaults to a freshly opened handle:
--- busy_timeout (5000ms), foreign_keys=ON, and — unless the connection
--- is read-only — journal_mode=WAL with synchronous=NORMAL.
--- @param raw_db lsqlite3.Database Raw handle from lsqlite3.open
--- @param opts Options Options passed to sqlite.open (may be nil)
--- @return boolean true when all defaults were applied
--- @return string Error message on failure
local function apply(raw_db: lsqlite3.Database, opts: Options): boolean, string
  local timeout_ms = 5000
  if opts and opts.busy_timeout_ms ~= nil then
    timeout_ms = opts.busy_timeout_ms
  end
  raw_db:busy_timeout(timeout_ms)

  if not (opts and opts.foreign_keys == false) then
    if raw_db:exec("PRAGMA foreign_keys = ON") ~= lsqlite3.OK then
      return false, raw_db:errmsg()
    end
  end

  if not (opts and (opts.wal == false or opts.read_only)) then
    -- Databases that cannot switch journal mode (e.g. :memory:) report
    -- their current mode instead of erroring; that clean no-op is fine.
    if raw_db:exec("PRAGMA journal_mode = WAL") ~= lsqlite3.OK
    or raw_db:exec("PRAGMA synchronous = NORMAL") ~= lsqlite3.OK then
      return false, raw_db:errmsg()
    end
  end

  return true
end

local record defaults
  type Options = Options
  apply: function(raw_db: lsqlite3.Database, opts: Options): boolean, string
end

local M: defaults = {
  apply = apply,
}

return M
