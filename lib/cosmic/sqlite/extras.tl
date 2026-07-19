--- Internal helper for cosmic.sqlite: the query_value and savepoint
--- conveniences attached onto a Database. Lives in its own file so
--- cosmic/sqlite/init.tl stays under the 500-line cap.

-- Mirrors of cosmic.sqlite's records (Teal records are nominal, so the
-- boundary crosses through `any`; same convention as cosmic.sqlite.params).
local record Values
  metamethod __call: function(self: Values): any ...
  err: function(self: Values): string
end

local record Stmt
  bind: function(self: Stmt, ...: any): boolean, string
  values: function(self: Stmt): Values
  close: function(self: Stmt)
end

local record Db
  prepare: function(self: Db, sql: string): Stmt | nil, string
  exec: function(self: Db, sql: string, ...: any): boolean, string
  query_value: function(self: Db, sql: string, ...: any): any, string
  savepoint: function(self: Db, fn: function(any)): boolean, string
end

--- Attach query_value and savepoint to a Database under construction.
--- The handle is typed `any` so cosmic.sqlite's nominal Database record
--- doesn't need to be duplicated here.
--- @param db_any any The Database being built by make_database
local function attach(db_any: any)
  local db = db_any as Db -- cast: from any

  --- Return the first column of the first row, for scalar lookups like
  --- COUNT(*) or a single-value SELECT. Returns nil with no error both
  --- when no row matches and when the value is SQL NULL; use query_one
  --- when that distinction matters.
  function db:query_value(sql: string, ...: any): any, string
    local stmt, err = self:prepare(sql)
    if not stmt then
      return nil, "query failed: " .. (err or "unknown error")
    end
    local st = stmt as Stmt -- cast: record union after guard
    local ok, bind_err = st:bind(...)
    if not ok then
      st:close()
      return nil, "bind failed: " .. (bind_err or "unknown error")
    end
    local vals = st:values()
    local v = vals()
    st:close()
    local step_err = vals:err()
    if step_err then
      return nil, step_err
    end
    return v
  end

  -- Savepoint names only have to be unique among currently-active
  -- savepoints; a monotonic counter per database over-satisfies that.
  local sp_counter = 0

  --- Execute fn within a savepoint — a nestable transaction. SAVEPOINT
  --- before fn; RELEASE if fn returns cleanly; ROLLBACK TO (then RELEASE)
  --- if fn raises or signals failure the library way — a returned `false`,
  --- or `nil` plus an error (nothing returned still releases). Inside a
  --- transaction only the savepoint's own changes are rolled back; at the
  --- top level a savepoint behaves like its own transaction.
  function db:savepoint(fn: function(any)): boolean, string
    sp_counter = sp_counter + 1
    local name = "cosmic_sp_" .. sp_counter
    local ok, err = self:exec("SAVEPOINT " .. name)
    if not ok then
      return false, err or "savepoint failed"
    end
    -- cast: pcall multi-return shape
    local success, result, result_err = pcall(fn, self) as(boolean, any, any)
    if not success then
      self:exec("ROLLBACK TO " .. name)
      self:exec("RELEASE " .. name)
      return false, (result as string) or "savepoint failed" -- cast: from any
    end
    if result == false or (result == nil and result_err ~= nil) then
      self:exec("ROLLBACK TO " .. name)
      self:exec("RELEASE " .. name)
      return false, (result_err as string) or "savepoint rolled back" -- cast: from any
    end
    return self:exec("RELEASE " .. name)
  end
end

return {attach = attach}
