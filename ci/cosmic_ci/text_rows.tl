--- [`Sqlite.text_rows`] as plain lists of strings, read through a prepared
--- statement. ci/ runs on the pinned driver as well as on the candidate:
--- the pinned release's rows are lists indexed by position, and the
--- candidate's are read through accessors, so a read of either kind does
--- not compile under the other. A statement is the same under both.
---
-- TODO: once ci/cosmic-driver.pin names a release whose Sqlite rows are read
-- with `row:text(index)`, call [`Sqlite.text_rows`] and read its rows so,
-- and delete this module.

local Sqlite = require("cosmic.sqlite")

local record TextRows
end

--- Every row of `sql` on `db` with `values` bound, each column as the bytes
--- SQLite holds (NULL is `""`), or nil and why. `values` is positional from
--- 1, `{}` binding NULL.
function TextRows.query(db: Sqlite.Handle, sql: string,
                        values?: {Sqlite.Value}): {{string}} | nil, string
  local statement, trouble = db:prepare(sql)
  if statement == nil then return nil, trouble end
  for index, value in ipairs(values or {}) do
    local bound: boolean
    local why: string
    if value.integer ~= nil then
      bound, why = statement:bind_integer(index, value.integer)
    elseif value.number ~= nil then
      bound, why = statement:bind_number(index, value.number)
    elseif value.text ~= nil then
      bound, why = statement:bind_text(index, value.text)
    elseif value.blob ~= nil then
      bound, why = statement:bind_blob(index, value.blob)
    else
      bound, why = statement:bind_null(index)
    end
    if not bound then
      statement:finalize()
      return nil, why
    end
  end
  local out: {{string}} = {}
  while true do
    local state, failure = statement:step()
    if state == nil then
      statement:finalize()
      return nil, failure ~= "" and failure or "sqlite: the step failed"
    end
    if state == "done" then break end
    local row: {string} = {}
    for column = 0, statement:columns() - 1 do
      row[column + 1] = statement:bytes(column)
    end
    out[#out + 1] = row
  end
  statement:finalize()
  return out, ""
end

return TextRows
