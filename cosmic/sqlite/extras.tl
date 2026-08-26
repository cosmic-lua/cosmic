--- Internal helper for cosmic.sqlite: the transaction and savepoint
--- conveniences attached onto a Database. Lives in its own file so
--- cosmic/sqlite/init.tl stays under the 500-line cap.

local bind_mod = require("cosmic.sqlite.bind")

-- The transaction/savepoint callback: an EXPLICIT verdict. `return
-- true` commits, `return false, why` rolls back; a raise rolls back;
-- any other return rolls back with an error naming the contract, so a
-- callback that forgets its verdict cannot commit by accident — Lua's
-- own truthiness would otherwise let `0`, `""`, a table, or bare nil
-- commit.
local type TxFn = function(any): boolean, string

local record Db
  exec: function(self: Db, sql: string, params?: bind_mod.Params): boolean, string
  transaction: function(self: Db, fn: TxFn): boolean, string
  savepoint: function(self: Db, fn: TxFn): boolean, string
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
    if why is string then return why end
    return what .. " rolled back"
  end
  return what .. " callback must return an explicit verdict:"
  .. " true to commit, or false plus a reason to roll back"
  .. " (got " .. tostring(verdict) .. ")"
end

--- Attach transaction and savepoint to a Database under
--- construction. The handle is typed `any` so cosmic.sqlite's nominal
--- Database record doesn't need to be duplicated here.
--- @param db_any any The Database being built by make_database
local function attach(db_any: any)
  if not (db_any is Db) then return end
  local db = db_any

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
    local success, verdict, why = pcall(fn, self)
    if not success then
      local _ok, _err = self:exec("ROLLBACK")
      -- cast: pcall slot 2 is the raised error, typed boolean from TxFn
      return false, (verdict as string) or "transaction failed"
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
    local success, verdict, why = pcall(fn, self)
    if not success then
      local _ok, _err = self:exec("ROLLBACK TO " .. name)
      local _ok2, _err2 = self:exec("RELEASE " .. name)
      -- cast: pcall slot 2 is the raised error, typed boolean from TxFn
      return false, (verdict as string) or "savepoint failed"
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
