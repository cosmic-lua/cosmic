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

--- The new id after an INSERT, and whether a DELETE found its row.
function Example.rowid_and_changes()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)"))
  assert(Sqlite.run(db, "INSERT INTO items (value) VALUES (?1)", { { text = "a" } }))
  local id = Sqlite.last_insert_rowid(db)
  assert(id == 1)
  assert(Sqlite.run(db, "DELETE FROM items WHERE id = ?1", { { integer = id } }))
  assert(Sqlite.changes(db) == 1)
  -- Deleting an id that is no longer there changes nothing: this is
  -- how a caller tells "removed" from "was never there" without a
  -- SELECT of its own first.
  assert(Sqlite.run(db, "DELETE FROM items WHERE id = ?1", { { integer = id } }))
  assert(Sqlite.changes(db) == 0)
  assert(db:close())
end

return Example
