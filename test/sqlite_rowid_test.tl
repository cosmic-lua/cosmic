local Sqlite = require("cosmic.sqlite")

local function test_last_insert_rowid_tracks_each_insert()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (value TEXT)"))
  assert(db:last_insert_rowid() == 0)
  assert(db:run("INSERT INTO items VALUES (?1)", { { text = "a" } }))
  assert(db:last_insert_rowid() == 1)
  assert(db:run("INSERT INTO items VALUES (?1)", { { text = "b" } }))
  assert(db:last_insert_rowid() == 2)
  local _, _ = db:close()
end

local function test_changes_counts_the_last_statement_only()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (value TEXT)"))
  assert(db:exec("INSERT INTO items VALUES ('a'), ('b'), ('c')"))
  assert(db:changes() == 3)
  assert(db:exec("DELETE FROM items WHERE value = 'a'"))
  assert(db:changes() == 1)
  assert(db:rows("SELECT * FROM items"))
  assert(db:changes() == 1)
  local _, _ = db:close()
end

local function test_close_is_idempotent()
  local db = assert(Sqlite.memory())
  assert(db:close())
  assert(db:close())
end

local function test_exec_runs_several_statements_one_run_cannot()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE a (value TEXT); CREATE TABLE b (value TEXT)"))
  assert(db:exec("INSERT INTO a VALUES ('x'); INSERT INTO b VALUES ('y')"))
  local a = assert(db:text_rows("SELECT value FROM a"))
  local b = assert(db:text_rows("SELECT value FROM b"))
  assert(#a == 1 and a[1]:text(1) == "x")
  assert(#b == 1 and b[1]:text(1) == "y")
  local _, _ = db:close()
end
