--- What a typed handle adds to its connection: `prepare` makes a
--- statement each run binds afresh, `exec` refuses a NUL, and `close`
--- says SQLite's code.

local Sqlite = require("cosmic.sqlite")

--- A prepared statement runs again and again, each run binding every
--- parameter from its values and leaving none bound after; a run short
--- of values answers why (RANGE) and leaves the statement to run again.
local function test_a_prepared_statement_binds_each_run_afresh()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (owner TEXT, n INTEGER)"))
  local insert = assert(db:prepare("INSERT INTO t (owner, n) VALUES (?1, ?2)"))
  assert(insert:parameters() == 2)
  for n = 1, 3 do assert(insert:run({ "me", n })) end
  local short, why = insert:run({ "me" })
  assert(short == false and why.code == Sqlite.RANGE, tostring(why))
  assert(insert:run({ "you", 4 }))
  local totals = assert(db:prepare("SELECT owner, sum(n) AS total FROM t WHERE owner = ?1"))
  assert(table.concat(totals:names(), " ") == "owner total")
  assert(assert(totals:one({ "me" })):integer(2) == 6)
  local rows = assert(totals:rows({ "you" }))
  assert(#rows == 1 and rows[1]:text(1) == "you")
  local q = assert(totals:query({ "me" }))
  local row = assert(q:read())
  assert(row:integer(2) == 6)
  q:close()
  assert(assert(totals:one({ "you" })):integer(2) == 4)
  insert:close()
  totals:close()
  assert(db:close())
end

--- A query on a prepared statement stopped by the statement's close ends
--- with no raise, and the handle closes once every statement is closed.
local function test_a_statement_closed_under_its_query_lets_the_handle_close()
  local db = assert(Sqlite.memory())
  local statement = assert(db:prepare("SELECT 1 UNION ALL SELECT 2"))
  local q = assert(statement:query())
  assert(assert(q:read()):integer(1) == 1)
  statement:close()
  local after, why = q:read()
  assert(after == nil and why ~= nil and why.code == Sqlite.MISUSE, tostring(why))
  q:close()
  statement:close()
  assert(db:close())
end

--- While a query reads a statement's rows, another call on the statement
--- answers why and leaves the rows as they were; once the query ends, the
--- statement runs again.
local function test_a_statement_under_an_open_query_does_not_run()
  local db = assert(Sqlite.memory())
  local cases: {string} = { "SELECT value FROM generate_series(1, 4)", "SELECT value FROM generate_series(?1, 4)" }
  for _, sql in ipairs(cases) do
    local statement = assert(db:prepare(sql))
    local values: {Sqlite.Param} = if statement:parameters() == 1 then { 1 } else {} end
    local q = assert(statement:query(values))
    assert(assert(q:read()):integer(1) == 1)
    local rows, busy = statement:rows(values)
    assert(rows == nil and busy.code == Sqlite.MISUSE, tostring(busy))
    local ran, again = statement:run(values)
    assert(ran == false and again.code == Sqlite.MISUSE)
    local second, twice = statement:query(values)
    assert(second == nil and twice.code == Sqlite.MISUSE)
    local seen: mut {integer} = {}
    for row in q:each() do seen[#seen + 1] = row:integer(1) end
    assert(table.concat(seen, " ") == "2 3 4", table.concat(seen, " "))
    assert(#assert(statement:rows(values)) == 4)
    statement:close()
  end
  assert(db:close())
end

--- A cell shown as text reads as SQLite's own CAST of it to text.
local function test_as_text_is_what_cast_as_text_answers()
  local db = assert(Sqlite.memory())
  local values: {number} = { 0.1, 1e20, 1.0, -0.0, 1e-7, 2.0 ^ 53 + 1, 1 / 3, 1e308, 4.9e-324, -2.5 }
  for _, x in ipairs(values) do
    local row = assert(db:one("SELECT ?1, CAST(?1 AS TEXT)", { x }))
    assert(row:as_text(1) == row:text(2), tostring(row:as_text(1)) .. " vs " .. row:text(2))
  end
  local row = assert(db:one("SELECT 7, 'a', x'00ff', NULL"))
  assert(row:as_text(1) == "7" and row:as_text(2) == "a" and row:as_text(3) == "\0\255" and row:as_text(4) == nil)
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
  statement:close()
  assert(db:close())
end
