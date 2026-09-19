local Sqlite = require("cosmic.sqlite")

local function test_exception_rolls_back_and_preserves_error()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (value TEXT)"))
  local marker = { message = "callback failed" }
  local called, failure = pcall(function(): any, string
    return Sqlite.transact(db, function(): boolean, string
      assert(db:exec("INSERT INTO items VALUES ('discard')"))
      error(marker)
      return true, ""
    end)
  end)
  assert(not called and failure == marker)
  local rows = assert(Sqlite.rows(db, "SELECT value FROM items"))
  assert(#rows == 0)
  assert(Sqlite.transact(db, function(): boolean, string
    return db:exec("INSERT INTO items VALUES ('keep')")
  end))
  rows = assert(Sqlite.rows(db, "SELECT value FROM items"))
  assert(#rows == 1 and rows[1][1] == "keep")
  db:close()
end

local function test_false_callback_rolls_back_with_reason()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (value TEXT)"))
  local ok, why = Sqlite.transact(db, function(): boolean, string
    assert(db:exec("INSERT INTO items VALUES ('discard')"))
    return false, "declined"
  end)
  assert(not ok and why == "declined")
  local rows = assert(Sqlite.rows(db, "SELECT value FROM items"))
  assert(#rows == 0)
  assert(db:exec("BEGIN; ROLLBACK"))
  db:close()
end

local function test_commit_failure_rolls_back()
  local db = assert(Sqlite.memory())
  assert(db:exec("PRAGMA foreign_keys = ON"))
  assert(db:exec("CREATE TABLE parent (id INTEGER PRIMARY KEY)"))
  assert(db:exec("CREATE TABLE child (parent_id INTEGER REFERENCES parent(id) " ..
    "DEFERRABLE INITIALLY DEFERRED)"))
  local ok, why = Sqlite.transact(db, function(): boolean, string
    return db:exec("INSERT INTO child VALUES (1)")
  end)
  assert(not ok and why:find("FOREIGN KEY", 1, true) ~= nil)
  local rows = assert(Sqlite.rows(db, "SELECT parent_id FROM child"))
  assert(#rows == 0)
  assert(db:exec("BEGIN; ROLLBACK"))
  db:close()
end
