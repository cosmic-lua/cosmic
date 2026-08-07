--- Internal helper for cosmic.sqlite: the query_value, transaction and
--- savepoint conveniences attached onto a Database. Lives in its own
--- file so cosmic/sqlite/init.tl stays under the 500-line cap.

-- Mirrors of cosmic.sqlite's records (Teal records are nominal, so the
-- boundary crosses through `any`; same convention as cosmic.sqlite.params).
local record Rows
  metamethod __call: function(self: Rows): {string: any}
  err: function(self: Rows): string | nil
  close: function(self: Rows): boolean, string
end

local record Stmt
  bind: function(self: Stmt, ...: any): boolean, string
  rows: function(self: Stmt): Rows
  column_name: function(self: Stmt, n: integer): string
  close: function(self: Stmt): boolean, string
end

-- The transaction/savepoint callback: `false` or `nil, err` rolls
-- back; `true` or nothing commits/releases. Variadic because Teal
-- cannot express optional returns — a fixed (boolean, string) type
-- would reject the no-return commit form outright — so typed callers
-- can return their verdict (or nothing) without a cast.
local type TxFn = function(any): any ...

local record Db
  prepare: function(self: Db, sql: string): Stmt | nil, string
  exec: function(self: Db, sql: string, ...: any): boolean, string
  query_value: function(self: Db, sql: string, ...: any): any, boolean, string
  transaction: function(self: Db, fn: TxFn): boolean, string
  savepoint: function(self: Db, fn: TxFn): boolean, string
end

--- Attach query_value and savepoint to a Database under construction.
--- The handle is typed `any` so cosmic.sqlite's nominal Database record
--- doesn't need to be duplicated here.
--- @param db_any any The Database being built by make_database
local function attach(db_any: any)
  local db = db_any as Db -- cast: from any

  --- Return the first column of the first row, for scalar lookups like
  --- COUNT(*) or a single-value SELECT. Three outcomes, three answers:
  --- (value, true) when a row matched — value nil means the value is
  --- SQL NULL — (nil, false) when no row matched, and (nil, false, err)
  --- on failure. The `found` flag is what separates "no row" from
  --- "NULL value", which two return slots could not.
  function db:query_value(sql: string, ...: any): any, boolean, string
    local stmt, err = self:prepare(sql)
    if not stmt then
      return nil, false, "query failed: " .. (err or "unknown error")
    end
    local st = stmt
    local ok, bind_err = st:bind(...)
    if not ok then
      local _ok, _err = st:close()
      return nil, false, "bind failed: " .. (bind_err or "unknown error")
    end
    -- One direct iterator call, not a `for` loop: the row arrives as a
    -- {column: value} map, so a NULL first column cannot be mistaken
    -- for end-of-iteration.
    local rows = st:rows()
    local row = rows()
    if row == nil then
      local step_err = rows:err()
      local _ok, _err = st:close()
      if step_err then
        return nil, false, step_err
      end
      return nil, false
    end
    -- column_name is valid only after the first step, which the row
    -- above performed.
    local name = st:column_name(1)
    local _rok, _rerr = rows:close()
    local _ok, _err = st:close()
    return row[name], true
  end

  --- Execute fn within a transaction. BEGIN before fn; COMMIT if fn returns
  --- cleanly; ROLLBACK if fn raises OR signals failure the library way -- a
  --- returned `false`, or `nil` plus an error (nothing returned still commits).
  --- A failing COMMIT (e.g. a deferred foreign-key violation) also rolls
  --- back, so the connection is never left inside an open transaction.
  function db:transaction(fn: TxFn): boolean, string
    local ok, err = self:exec("BEGIN IMMEDIATE")
    if not ok then
      return false, err or "begin failed"
    end
    -- cast: pcall variadic returns
    local success, result, result_err = pcall(fn, self) as (boolean, any, any)
    if not success then
      local _ok, _err = self:exec("ROLLBACK")
      return false, (result as string) or "transaction failed" -- cast: from any
    end
    if result == false or (result == nil and result_err ~= nil) then
      local _ok, _err = self:exec("ROLLBACK")
      return false, (result_err as string) or "transaction rolled back" -- cast: from any
    end
    local commit_ok, commit_err = self:exec("COMMIT")
    if not commit_ok then
      local rollback_ok, rollback_err = self:exec("ROLLBACK")
      if not rollback_ok then
        return false, (commit_err or "commit failed") ..
        "; rollback also failed: " .. (rollback_err or "unknown error")
      end
      return false, commit_err or "commit failed"
    end
    return true
  end

  -- Savepoint names only have to be unique among currently-active
  -- savepoints; a monotonic counter per database over-satisfies that.
  local sp_counter = 0

  --- Execute fn within a savepoint — a nestable transaction. SAVEPOINT
  --- before fn; RELEASE if fn returns cleanly; ROLLBACK TO (then RELEASE)
  --- if fn raises or signals failure the library way — a returned `false`,
  --- or `nil` plus an error (nothing returned still releases). Inside a
  --- transaction only the savepoint's own changes are rolled back; at the
  --- top level a savepoint behaves like its own transaction. A failing
  --- RELEASE (e.g. a deferred foreign-key violation) also rolls back to
  --- the savepoint, so it is never left open.
  function db:savepoint(fn: TxFn): boolean, string
    sp_counter = sp_counter + 1
    local name = "cosmic_sp_" .. sp_counter
    local ok, err = self:exec("SAVEPOINT " .. name)
    if not ok then
      return false, err or "savepoint failed"
    end
    -- cast: pcall multi-return shape
    local success, result, result_err = pcall(fn, self) as (boolean, any, any)
    if not success then
      local _ok, _err = self:exec("ROLLBACK TO " .. name)
      local _ok, _err = self:exec("RELEASE " .. name)
      return false, (result as string) or "savepoint failed" -- cast: from any
    end
    if result == false or (result == nil and result_err ~= nil) then
      local _ok, _err = self:exec("ROLLBACK TO " .. name)
      local _ok, _err = self:exec("RELEASE " .. name)
      return false, (result_err as string) or "savepoint rolled back" -- cast: from any
    end
    local release_ok, release_err = self:exec("RELEASE " .. name)
    if not release_ok then
      local rollback_ok, rollback_err = self:exec("ROLLBACK TO " .. name)
      if not rollback_ok then
        return false, (release_err or "release failed") ..
        "; rollback also failed: " .. (rollback_err or "unknown error")
      end
      local _ok, _err = self:exec("RELEASE " .. name)
      return false, release_err or "release failed"
    end
    return true
  end
end

return {attach = attach}
