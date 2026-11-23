--- What a typed handle adds to its connection: `prepare` binds the values
--- it is given, `exec` refuses a NUL, and `close` says SQLite's code.

local Sqlite = require("cosmic.sqlite")

--- Given values, `prepare` binds them; without, it binds none and the
--- statement's own `bind_*` methods do.
local function test_prepare_binds_the_values_it_is_given()
  local db = assert(Sqlite.memory())
  local bound = assert(db:prepare("SELECT ?1, ?2", { { integer = 7 }, { text = "seven" } }))
  assert(bound:step() == "row")
  assert(bound:integer(0) == 7 and bound:bytes(1) == "seven")
  bound:finalize()
  local unbound = assert(db:prepare("SELECT ?1"))
  assert(unbound:bind_integer(1, 8))
  assert(unbound:step() == "row")
  assert(unbound:integer(0) == 8)
  unbound:finalize()
  local short, why = db:prepare("SELECT ?1, ?2", { { integer = 7 } })
  assert(short == nil and why.code == Sqlite.RANGE, tostring(why))
  assert(db:close())
end

--- SQL holding a NUL is refused with why, as SQLite would read it only to
--- the NUL.
local function test_exec_refuses_a_nul()
  local db = assert(Sqlite.memory())
  local ran, why = db:exec("CREATE TABLE t (a);\0DROP TABLE t")
  assert(not ran and why.code == Sqlite.MISUSE, tostring(why))
  assert(#assert(db:rows("SELECT name FROM sqlite_schema")) == 0)
  assert(db:close())
end

--- A handle with a statement open does not close, and says SQLite's
--- code; once the statement is finalized it closes.
local function test_close_waits_for_open_statements()
  local db = assert(Sqlite.memory())
  local statement = assert(db:prepare("SELECT 1"))
  local closed, why = db:close()
  assert(not closed and why.code == Sqlite.BUSY, tostring(why))
  statement:finalize()
  assert(db:close())
end
