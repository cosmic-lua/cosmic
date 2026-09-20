local Sqlite = require("cosmic.sqlite")

local function test_last_insert_rowid_tracks_each_insert()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (value TEXT)"))
  assert(Sqlite.last_insert_rowid(db) == 0)
  assert(Sqlite.run(db, "INSERT INTO items VALUES (?1)", { { text = "a" } }))
  assert(Sqlite.last_insert_rowid(db) == 1)
  assert(Sqlite.run(db, "INSERT INTO items VALUES (?1)", { { text = "b" } }))
  assert(Sqlite.last_insert_rowid(db) == 2)
  db:close()
end

local function test_changes_counts_the_last_statement_only()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (value TEXT)"))
  assert(db:exec("INSERT INTO items VALUES ('a'), ('b'), ('c')"))
  assert(Sqlite.changes(db) == 3)
  assert(db:exec("DELETE FROM items WHERE value = 'a'"))
  assert(Sqlite.changes(db) == 1)
  assert(Sqlite.rows(db, "SELECT * FROM items"))
  assert(Sqlite.changes(db) == 1)
  db:close()
end

local function test_close_is_idempotent()
  local db = assert(Sqlite.memory())
  assert(Sqlite.close(db))
  assert(Sqlite.close(db))
end
