--- Worked examples for `cosmic.sqlite`, shown by `cosmic docs` and run by
--- `cosmic test`.

local Sqlite = require("cosmic.sqlite")

local Example = {}

--- Read a value without losing its SQLite storage class.
function Example.typed_row()
  local db = assert(Sqlite.memory())
  local rows = assert(Sqlite.rows(db, "SELECT 42, 'answer', NULL"))
  assert(rows[1][1].kind == "integer" and rows[1][1].integer == 42)
  assert(rows[1][2].kind == "text" and rows[1][2].text == "answer")
  assert(rows[1][3].kind == "null")
  assert(db:close())
end

return Example
