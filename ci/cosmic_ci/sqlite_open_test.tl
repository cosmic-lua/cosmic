local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local SqliteOpen = require("cosmic_ci.sqlite_open")

--- A writable open creates the file and can write it; the plain open of
--- the same path reads it and refuses a write.
local function test_writable_creates_and_writes(tmp: string)
  local path = tmp .. "/made.db"
  local db = assert(SqliteOpen.writable(path))
  assert(db:exec("CREATE TABLE t (n INTEGER); INSERT INTO t VALUES (1)"))
  assert(db:close())
  local reader = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(reader, "SELECT n FROM t"))
  assert(rows[1][1] == "1")
  assert(not reader:exec("INSERT INTO t VALUES (2)"))
  assert(reader:close())
  assert(Fs.exists(path))
end
