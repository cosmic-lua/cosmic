--- Internal helper for cosmic.sqlite: the query_value, transaction and
--- savepoint conveniences attached onto a Database. Lives in its own
--- file so cosmic/sqlite/init.tl stays under the 500-line cap.

local bind_mod = require("cosmic.sqlite.bind")

-- Mirrors of cosmic.sqlite's records (Teal records are nominal, so the
-- boundary crosses through `any`; same convention as cosmic.sqlite.stmt_cache).
local record Rows
  metamethod __call: function(self: Rows): {string: any}
  err: function(self: Rows): string | nil
  close: function(self: Rows): boolean, string
end

local record Stmt
  bind_list: function(self: Stmt, values: {any}): boolean, string
  bind_named: function(self: Stmt, params: {string: any}): boolean, string
  rows: function(self: Stmt): Rows
  column_name: function(self: Stmt, n: integer): string
  close: function(self: Stmt): boolean, string
end

-- The transaction/savepoint callback: an EXPLICIT verdict. `return
-- true` commits, `return false, why` rolls back; a raise rolls back;
-- any other return rolls back with an error naming the contract, so a
-- callback that forgets its verdict cannot commit by accident (the old
-- variadic contract committed on `0`, `""`, a table, or bare nil).
local type TxFn = function(any): boolean, string

local record Db
  prepare: function(self: Db, sql: string): Stmt | nil, string
  exec: function(self: Db, sql: string, params?: bind_mod.Params): boolean, string
  query_value: function(self: Db, sql: string, params?: bind_mod.Params): any, boolean, string
  transaction: function(self: Db, fn: TxFn): boolean, string
  savepoint: function(self: Db, fn: TxFn): boolean, string
end

--- Bind a Params table through the Statement wrapper, dispatching on
--- its shape the same way the raw bind_params does.
--- @param st Stmt The prepared statement wrapper
--- @param params bind_mod.Params The parameter table
--- @return boolean Whether every bind succeeded
--- @return string Error message on a failed bind
local function bind_dispatch(st: Stmt, params: bind_mod.Params): boolean, string
  local list = params as {any} -- cast: array-part probe of the params table
  if #list > 0 then
    return st:bind_list(list)
  end
  local named = params as {string: any} -- cast: map view of the params table
  if next(named) ~= nil then
    return st:bind_named(named)
  end
  return true
end

--- Read the callback's verdict into a rollback decision. Returns nil
--- for a clean commit, or the rollback reason.
--- @param verdict any What the callback returned first
--- @param why any What the callback returned second
--- @param what string "transaction" or "savepoint", for messages
--- @return string | nil The rollback reason, or nil to commit
local function rollback_reason(verdict: any, why: any, what: string): string | nil
  if verdict == true then
    return nil
  end
  if verdict == false then
    return (why as string) or (what .. " rolled back") -- cast: from any
  end
  return what .. " callback must return an explicit verdict:"
  .. " true to commit, or false plus a reason to roll back"
  .. " (got " .. tostring(verdict) .. ")"
end

--- Attach query_value, transaction and savepoint to a Database under
--- construction. The handle is typed `any` so cosmic.sqlite's nominal
--- Database record doesn't need to be duplicated here.
--- @param db_any any The Database being built by make_database
local function attach(db_any: any)
  local db = db_any as Db -- cast: from any

  --- Return the first column of the first row, for scalar lookups like
  --- COUNT(*) or a single-value SELECT. Three outcomes, three answers:
  --- (value, true) when a row matched — value nil means the value is
  --- SQL NULL — (nil, false) when no row matched, and (nil, false, err)
  --- on failure. The `found` flag is what separates "no row" from
  --- "NULL value", which two return slots could not.
  function db:query_value(sql: string, params?: bind_mod.Params): any, boolean, string
    local stmt, err = self:prepare(sql)
    if not stmt then
      return nil, false, "query failed: " .. (err or "unknown error")
    end
    local st = stmt
    if params then
      local ok, bind_err = bind_dispatch(st, params)
      if not ok then
        local _ok, _err = st:close()
        return nil, false, "bind failed: " .. (bind_err or "unknown error")
      end
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

  --- Execute fn within a transaction, with an explicit verdict. BEGIN
  --- before fn; COMMIT only when fn returns `true`; ROLLBACK when it
  --- raises, returns `false, why`, or returns anything else (the
  --- contract error names what arrived). A failing COMMIT (e.g. a
  --- deferred foreign-key violation) also rolls back, so the
  --- connection is never left inside an open transaction.
  function db:transaction(fn: TxFn): boolean, string
    local ok, err = self:exec("BEGIN IMMEDIATE")
    if not ok then
      return false, err or "begin failed"
    end
    -- cast: pcall variadic returns
    local success, verdict, why = pcall(fn, self) as (boolean, any, any)
    if not success then
      local _ok, _err = self:exec("ROLLBACK")
      return false, (verdict as string) or "transaction failed" -- cast: from any
    end
    local reason = rollback_reason(verdict, why, "transaction")
    if reason then
      local _ok, _err = self:exec("ROLLBACK")
      return false, reason
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

  --- Execute fn within a savepoint — a nestable transaction — with
  --- transaction's verdict rules. SAVEPOINT before fn; RELEASE only
  --- when fn returns `true`; ROLLBACK TO (then RELEASE) when it
  --- raises, returns `false, why`, or returns anything else. Inside a
  --- transaction only the savepoint's own changes are rolled back; at
  --- the top level a savepoint behaves like its own transaction. A
  --- failing RELEASE (e.g. a deferred foreign-key violation) also
  --- rolls back to the savepoint, so it is never left open.
  function db:savepoint(fn: TxFn): boolean, string
    sp_counter = sp_counter + 1
    local name = "cosmic_sp_" .. sp_counter
    local ok, err = self:exec("SAVEPOINT " .. name)
    if not ok then
      return false, err or "savepoint failed"
    end
    -- cast: pcall multi-return shape
    local success, verdict, why = pcall(fn, self) as (boolean, any, any)
    if not success then
      local _ok, _err = self:exec("ROLLBACK TO " .. name)
      local _ok2, _err2 = self:exec("RELEASE " .. name)
      return false, (verdict as string) or "savepoint failed" -- cast: from any
    end
    local reason = rollback_reason(verdict, why, "savepoint")
    if reason then
      local _ok, _err = self:exec("ROLLBACK TO " .. name)
      local _ok2, _err2 = self:exec("RELEASE " .. name)
      return false, reason
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
