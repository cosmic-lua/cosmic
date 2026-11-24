--- Every handle [`cosmic.sqlite`] opens is in SQLite's defensive mode and
--- checks each cell's size as it reads it, so SQL it runs cannot corrupt the
--- file; `defensive = false` turns the mode off for code that writes the
--- schema itself.

local Sqlite = require("cosmic.sqlite")

--- The one text cell `sql` answers on `db`.
local function answer(db: Sqlite.Handle, sql: string): string
  return assert(assert(db:text_rows(sql))[1]):text(1)
end

local function test_a_handle_cannot_write_its_schema()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (a)"))
  assert(db:exec("PRAGMA writable_schema = ON"))
  local written, why = db:exec("UPDATE sqlite_schema SET sql = 'CREATE TABLE t (b)' WHERE name = 't'")
  assert(not written, "the schema was written")
  assert(tostring(why):find("may not be modified", 1, true) ~= nil, tostring(why))
  local before = answer(db, "PRAGMA schema_version")
  assert(db:exec("PRAGMA schema_version = 99"))
  assert(answer(db, "PRAGMA schema_version") == before, "the schema cookie was written")
  assert(db:close())
end

local function test_journal_mode_off_leaves_the_mode(tmp: string)
  local db = assert(Sqlite.open(tmp .. "/off.db", { writable = true }))
  assert(answer(db, "PRAGMA journal_mode = OFF") == "delete")
  assert(answer(db, "PRAGMA journal_mode = MEMORY") == "memory")
  assert(db:close())
end

local function test_a_shadow_table_is_read_only()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE VIRTUAL TABLE f USING fts5(body); INSERT INTO f VALUES ('hello')"))
  local written, why = db:exec("DELETE FROM f_data")
  assert(not written, "the shadow table was written")
  assert(tostring(why):find("may not be modified", 1, true) ~= nil, tostring(why))
  assert(answer(db, "SELECT body FROM f WHERE f MATCH 'hello'") == "hello")
  assert(db:close())
end

local function test_each_cell_is_checked_as_it_is_read()
  local db = assert(Sqlite.memory())
  assert(answer(db, "PRAGMA cell_size_check") == "1")
  assert(db:close())
end

local function test_defensive_false_lets_the_schema_be_written(tmp: string)
  local db = assert(Sqlite.open(tmp .. "/raw.db", { writable = true, defensive = false }))
  assert(db:exec("CREATE TABLE t (a)"))
  local before = math.tointeger(tonumber(answer(db, "PRAGMA schema_version")))
  assert(before ~= nil)
  assert(db:exec("PRAGMA schema_version = " .. tostring(before + 5)))
  assert(answer(db, "PRAGMA schema_version") == tostring(before + 5))
  assert(answer(db, "PRAGMA journal_mode = OFF") == "off")
  assert(answer(db, "PRAGMA cell_size_check") == "1")
  assert(db:close())
end

