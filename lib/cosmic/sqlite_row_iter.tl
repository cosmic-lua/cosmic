--- Internal helper for cosmic.sqlite: the row iterator for db:query's hot
--- path. Collapses what used to be a full Statement object (~10 method
--- closures) + Statement:rows() + a close-on-drain wrapper into a single
--- iterator that steps the raw statement directly, resolves column names
--- once on the first row, and releases the statement when iteration drains.
--- Lives in its own file so cosmic/sqlite.tl stays under the 500-line cap.

local record RawStatement
  bind: function(self: RawStatement, n: number, value?: any): number
  step: function(self: RawStatement): number
  reset: function(self: RawStatement)
  finalize: function(self: RawStatement): number
  get_value: function(self: RawStatement, n: number): any
  columns: function(self: RawStatement): number
  get_name: function(self: RawStatement, n: number): string
end

local record RawDatabase
  errmsg: function(self: RawDatabase): string
end

-- Callable row iterator: `for row in iter do ... end`, then `iter:err()`
-- surfaces a post-drain step error. Same shape as cosmic.sqlite's Rows.
local record Rows
  metamethod __call: function(self: Rows): {string: any}
  err: function(self: Rows): string
end

-- on_close mirrors stmt_cache:checkout — non-nil returns the shared cached
-- slot when iteration ends; nil means a throwaway statement to finalize.
local type OnClose = function(RawStatement)

  --- Build the row iterator over an already-reset+bound raw statement.
  --- Raw handles are typed `any` so callers don't need nominally-identical
  --- record types (same convention as sqlite_stmt_cache).
  --- @param raw_stmt_any any The prepared, bound statement to step
  --- @param raw_db_any any The owning database (for errmsg)
  --- @param on_close_any any Release callback, or nil to finalize
  --- @param row_code number sqlite3.ROW
  --- @param done_code number sqlite3.DONE
  --- @return Rows The callable row iterator
  local function make(raw_stmt_any: any, raw_db_any: any, on_close_any: any, row_code: number, done_code: number): Rows
    local raw_stmt = raw_stmt_any as RawStatement
    local raw_db = raw_db_any as RawDatabase
    local on_close = on_close_any as OnClose
    local step_err: string
    local col_count = raw_stmt:columns()
    local col_names: {integer: string}
    local first_call = true
    local done = false

    local iter = setmetatable({} as Rows, {
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
                col_names[(idx + 1) as integer] = raw_stmt:get_name(idx)
              end
            end
            local row: {string: any} = {}
            for idx = 0, col_count - 1 do
              row[col_names[(idx + 1) as integer]] = raw_stmt:get_value(idx)
            end
            return row
          end
          -- Anything but a clean SQLITE_DONE is a real error to surface.
          done = true
          if rc ~= done_code then
            step_err = raw_db:errmsg()
          end
          if on_close then
            on_close(raw_stmt)
          else
            local _ = raw_stmt:finalize()
          end
          return nil
        end,
      })
    iter.err = function(_: Rows): string return step_err end
    return iter
  end

  --- Reset + positional-bind a raw statement, then return its row iterator.
  --- Resets first (even with no args) so a reused cached statement is cleared.
  --- On a bind failure the statement is released and (nil, message) returned.
  --- @param raw_stmt_any any The checked-out statement
  --- @param raw_db_any any The owning database (for errmsg)
  --- @param on_close_any any Release callback, or nil to finalize
  --- @param ok_code number sqlite3.OK
  --- @param row_code number sqlite3.ROW
  --- @param done_code number sqlite3.DONE
  --- @param ... any Positional bind parameters
  --- @return Rows | nil The row iterator, or nil on bind failure
  --- @return string Error message when binding failed
  local function query(raw_stmt_any: any, raw_db_any: any, on_close_any: any, ok_code: number, row_code: number, done_code: number, ...: any): Rows | nil, string
    local raw_stmt = raw_stmt_any as RawStatement
    local raw_db = raw_db_any as RawDatabase
    local on_close = on_close_any as OnClose
    raw_stmt:reset()
    local n = select("#", ...) as integer
    for i = 1, n do
      local rc = raw_stmt:bind(i, (select(i, ...)))
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
