local Sqlite = require("cosmic.sqlite")

local function numbers(count: integer): Sqlite.Handle
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (n INTEGER, label TEXT)"))
  for n = 1, count do
    assert(Sqlite.run(db, "INSERT INTO t VALUES (?1, ?2)",
      { { integer = n }, { text = "n" .. tostring(n) } }))
  end
  return db
end

--- A query gives the rows `rows` gives, one at a time, then ends, and
--- keeps ending; the statement is finalized, so the handle closes.
local function test_a_query_reads_what_rows_reads()
  local db = numbers(3)
  local q = assert(Sqlite.query(db, "SELECT n, label FROM t WHERE n >= ?1 ORDER BY n",
    { { integer = 2 } }))
  local first = assert(q:read())
  assert(first[1].integer == 2 and first[2].text == "n2")
  local second = assert(q:read())
  assert(second[1].integer == 3 and second[2].text == "n3")
  for _ = 1, 2 do
    local row, trouble = q:read()
    assert(row == nil and trouble == "")
  end
  assert(q:failure() == "")
  assert(db:close())
end

local function test_each_reads_every_row()
  local db = numbers(100)
  local q = assert(Sqlite.query(db, "SELECT n FROM t ORDER BY n"))
  local total = 0
  for row in q:each() do total = total + row[1].integer end
  assert(total == 5050 and q:failure() == "")
  assert(db:close())
end

--- A `break` out of a loop over a `<close>` query finalizes it, so the
--- handle can close; without the close it could not.
local function test_a_close_variable_finalizes_a_query_left_early()
  local db = numbers(10)
  do
    local q <close> = assert(Sqlite.query(db, "SELECT n FROM t"))
    for _ in q:each() do break end
    local busy, _ = db:close()
    assert(not busy, "the open statement holds the handle")
  end
  assert(db:close())
end

--- A read after close fails, and closing again does nothing.
local function test_a_closed_query_fails_a_read()
  local db = numbers(2)
  local q = assert(Sqlite.query(db, "SELECT n FROM t"))
  assert(q:read())
  q:close()
  q:close()
  local row, trouble = q:read()
  assert(row == nil and trouble:find("closed", 1, true) ~= nil, trouble)
  assert(db:close())
end

--- A statement that does not prepare, or parameters that do not bind,
--- answer nil and why, and leave nothing open.
local function test_a_query_that_cannot_start_says_why()
  local db = numbers(1)
  local q, trouble = Sqlite.query(db, "SELECT nothing FROM nowhere")
  assert(q == nil and trouble ~= "")
  local unbound, why = Sqlite.query(db, "SELECT ?1")
  assert(unbound == nil and why ~= "")
  assert(db:close())
end

--- A step that fails ends the rows with its reason, the rows before it
--- read, and the statement finalized.
local function test_a_failed_step_ends_the_rows_with_why()
  local db = assert(Sqlite.memory())
  local q = assert(Sqlite.query(db,
    "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 3) " ..
    "SELECT CASE WHEN n < 3 THEN n ELSE json('not json') END FROM c"))
  local seen = 0
  for _ in q:each() do seen = seen + 1 end
  assert(seen == 2, tostring(seen))
  local failure = q:failure()
  assert(failure ~= "", "the failed step was not reported")
  local row, trouble = q:read()
  assert(row == nil and trouble == failure)
  assert(db:close())
end
