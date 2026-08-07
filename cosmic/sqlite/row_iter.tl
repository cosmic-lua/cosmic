--- Internal helper for cosmic.sqlite: the row iterator for db:query's hot
--- path. One iterator that steps the raw statement directly, resolves
--- column names once on the first row, and releases the statement when
--- iteration drains -- instead of a full Statement object (~10 method
--- closures) plus Statement:rows() plus a close-on-drain wrapper.
--- Lives in its own file so cosmic/sqlite.tl stays under the 500-line cap.

local bind_mod = require("cosmic.sqlite.bind")
local lsqlite3 = require("cosmo.lsqlite3")

-- Callable row iterator: `for row in iter do ... end`, then `iter:err()`
-- surfaces a post-drain step error. Same shape as cosmic.sqlite's Rows.
-- `close` releases the statement without draining; it also runs on scope
-- exit (`local rows <close> = db:query(...)`) and on garbage collection,
-- so an abandoned iterator cannot leak its prepared statement.
local record Rows
  metamethod __call: function(self: Rows): {string: any}
  metamethod __close: function(self: Rows)
  err: function(self: Rows): string | nil
  close: function(self: Rows): boolean, string
end

-- on_close mirrors stmt_cache:checkout — non-nil returns the shared cached
-- slot when iteration ends; nil means a throwaway statement to finalize.
local type OnClose = bind_mod.OnClose

--- Build the row iterator over an already-reset+bound raw statement.
--- @param raw_stmt lsqlite3.Statement The prepared, bound statement to step
--- @param raw_db lsqlite3.Database The owning database (for errmsg)
--- @param on_close OnClose Release callback, or nil to finalize
--- @param row_code number sqlite3.ROW
--- @param done_code number sqlite3.DONE
--- @return Rows The callable row iterator
local function make(raw_stmt: lsqlite3.Statement, raw_db: lsqlite3.Database, on_close: OnClose, row_code: number, done_code: number): Rows
  local step_err: string
  local col_count = raw_stmt:columns()
  local col_names: {integer: string}
  local first_call = true
  local done = false

  -- Release exactly once: return the shared cached slot, or finalize a
  -- throwaway. Reached from drain, from close/<close>, and from __gc.
  -- Reports a finalize failure (close() forwards it); a repeat call is
  -- a clean true.
  local function release(): boolean, string
    if done then
      return true
    end
    done = true
    if on_close then
      on_close(raw_stmt)
    elseif raw_stmt:isopen() then
      -- isopen guard: the binding finalizes statements when the
      -- database closes, and finalize on that dead vm throws — from
      -- __gc, no less. Never raise from a release path.
      local rc = raw_stmt:finalize()
      if rc ~= 0 then
        return false, raw_db:errmsg()
      end
    end
    return true
  end

  local iter = setmetatable({} as Rows, { -- cast: table seeded as record
      __call = function(_: Rows): {string: any}
        if done then
          return nil
        end
        local rc = raw_stmt:step()
        if rc == row_code then
          -- Column names require step to have run first; resolve once.
          if first_call then
            first_call = false
            col_names = {}
            for idx = 0, col_count - 1 do
              col_names[(idx + 1)] = raw_stmt:get_name(idx)
            end
          end
          local row: {string: any} = {}
          for idx = 0, col_count - 1 do
            row[col_names[(idx + 1)]] = raw_stmt:get_value(idx)
          end
          return row
        end
        -- Anything but a clean SQLITE_DONE is a real error to surface.
        if rc ~= done_code then
          step_err = raw_db:errmsg()
        end
        local _ok, _err = release()
        return nil
      end,
      __close = function(_: Rows)
        local _ok, _err = release()
      end,
      __gc = function(_: Rows)
        local _ok, _err = release()
      end,
    })
  iter.err = function(_: Rows): string | nil return step_err end
  iter.close = function(_: Rows): boolean, string
    return release()
  end
  return iter
end

--- Reset + bind a raw statement from a Params table, then return its
--- row iterator. Resets first (even with no params) so a reused cached
--- statement is cleared. On a bind failure the statement is released
--- and (nil, message) returned.
--- @param raw_stmt lsqlite3.Statement The checked-out statement
--- @param raw_db lsqlite3.Database The owning database (for errmsg)
--- @param on_close OnClose Release callback, or nil to finalize
--- @param ok_code number sqlite3.OK
--- @param row_code number sqlite3.ROW
--- @param done_code number sqlite3.DONE
--- @param params bind_mod.Params? Positional or named bind parameters
--- @return Rows | nil The row iterator, or nil on bind failure
--- @return string Error message when binding failed
local function query(raw_stmt: lsqlite3.Statement, raw_db: lsqlite3.Database, on_close: OnClose, ok_code: number, row_code: number, done_code: number, params?: bind_mod.Params): Rows | nil, string
  raw_stmt:reset()
  if params then
    local rc = bind_mod.bind_params(raw_stmt, ok_code, params)
    if rc ~= ok_code then
      local bind_err = raw_db:errmsg()
      if on_close then
        on_close(raw_stmt)
      else
        local _ = raw_stmt:finalize()
      end
      return nil, "bind failed: " .. (bind_err or "unknown error")
    end
  end
  return make(raw_stmt, raw_db, on_close, row_code, done_code)
end

return {make = make, query = query}
