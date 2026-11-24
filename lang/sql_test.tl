--- The reads of SQL against a schema ([`lang.sql`]) that the checker's tests do not reach.
local Sql = require("lang.sql")
local Sqlite = require("cosmic.sqlite")

--- A worker the checker forks disowns the databases its parent opened, and the reads open their own.
local function test_reads_go_on_after_the_process_disowns_its_databases()
  local ddl = "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"
  local before = assert(Sql.read(ddl, "SELECT body FROM notes"))
  assert(before.refused == nil and #before.columns == 1)
  Sqlite.disown()
  local after = assert(Sql.read(ddl, "SELECT body FROM notes"))
  assert(after.refused == nil, after.refused)
  local column = assert(after.columns[1])
  assert(column.origin == "notes.body" and column.kind == "text")
  local refused = assert(Sql.read(ddl, "SELECT nme FROM notes"))
  assert(refused.refused == "no such column: nme", refused.refused)
end
