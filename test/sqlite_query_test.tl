local Sqlite = require("cosmic.sqlite")

local function numbers(count: integer): Sqlite.Handle
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (n INTEGER, label TEXT)"))
  for n = 1, count do
    assert(db:run("INSERT INTO t VALUES (?1, ?2)",
      { { integer = n }, { text = "n" .. tostring(n) } }))
  end
  return db
end

--- A query gives the rows `rows` gives, one at a time, then ends, and
--- keeps ending; the statement is finalized, so the handle closes.
local function test_a_query_reads_what_rows_reads()
  local db = numbers(3)
  local q = assert(db:query("SELECT n, label FROM t WHERE n >= ?1 ORDER BY n",
    { { integer = 2 } }))
  local first = assert(q:read())
  assert(first:integer(1) == 2 and first:text(2) == "n2")
  local second = assert(q:read())
  assert(second:integer(1) == 3 and second:text(2) == "n3")
  for _ = 1, 2 do
    local row, trouble = q:read()
    assert(row == nil and trouble == nil)
  end
  assert(q:failure() == nil)
  assert(db:close())
end

local function test_each_reads_every_row()
  local db = numbers(100)
  local q = assert(db:query("SELECT n FROM t ORDER BY n"))
  local total = 0
  for row in q:each() do total = total + row:integer(1) end
  assert(total == 5050 and q:failure() == nil)
  assert(db:close())
end

--- A `break` out of a loop over a `<close>` query finalizes it, so the
--- handle can close; without the close it could not.
local function test_a_close_variable_finalizes_a_query_left_early()
  local db = numbers(10)
  do
    local q <close> = assert(db:query("SELECT n FROM t"))
    for _ in q:each() do break end
    local busy, _ = db:close()
    assert(not busy, "the open statement holds the handle")
  end
  assert(db:close())
end

--- Leaving the block of a `<close>` query closes it, at the end of the
--- block and on an error out of it, with rows still unread.
local function test_a_close_variable_closes_a_query_at_the_end_of_its_block()
  local db = numbers(10)
  do
    local q <close> = assert(db:query("SELECT n FROM t"))
    assert(q:read())
    local refused, _ = db:close()
    assert(not refused, "the open statement holds the handle")
  end
  assert(db:close())

  local other = numbers(10)
  local ok, _ = pcall(function()
    local q <close> = assert(other:query("SELECT n FROM t"))
    assert(q:read())
    error("left early")
  end)
  assert(not ok)
  assert(other:close())
end

--- A read after close fails, and closing again does nothing.
local function test_a_closed_query_fails_a_read()
  local db = numbers(2)
  local q = assert(db:query("SELECT n FROM t"))
  assert(q:read())
  local _, _ = q:close()
  local _, _ = q:close()
  local row, trouble = q:read()
  assert(row == nil and tostring(trouble):find("closed", 1, true) ~= nil, trouble)
  assert(db:close())
end

--- A statement that does not prepare, or parameters that do not bind,
--- answer nil and why, and leave nothing open.
local function test_a_query_that_cannot_start_says_why()
  local db = numbers(1)
  local q, trouble = db:query("SELECT nothing FROM nowhere")
  assert(q == nil and trouble.message ~= "")
  local unbound, why = db:query("SELECT ?1")
  assert(unbound == nil and why.message ~= "")
  assert(db:close())
end

--- A step that fails ends the rows with its reason, the rows before it
--- read, and the statement finalized.
local function test_a_failed_step_ends_the_rows_with_why()
  local db = assert(Sqlite.memory())
  local q = assert(db:query(
    "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 3) " ..
      "SELECT CASE WHEN n < 3 THEN n ELSE json('not json') END FROM c"))
  local seen = 0
  for _ in q:each() do seen = seen + 1 end
  assert(seen == 2, tostring(seen))
  local failure = q:failure()
  assert(failure ~= nil, "the failed step was not reported")
  local row, trouble = q:read()
  assert(row == nil and trouble == failure)
  assert(db:close())
end

--- A schema change between the query and its read re-prepares the
--- statement: the rows carry the columns it has now, and a column gone
--- is not asked for.
local function test_a_query_reads_the_columns_the_statement_has_now()
  for _, change in ipairs({ "ALTER TABLE t DROP COLUMN label", "ALTER TABLE t ADD COLUMN extra" }) do
    local db = numbers(2)
    local q = assert(db:query("SELECT * FROM t ORDER BY n"))
    assert(db:exec(change))
    local row, trouble = q:read()
    assert(row ~= nil, change .. ": " .. tostring(trouble))
    local want = if change:find("DROP", 1, true) then 1 else 3 end
    assert(row:count() == want, change .. ": " .. tostring(row:count()) .. " columns")
    local _, _ = q:close()
    assert(db:close())
  end
end

--- `floor` after a time of 24:00:00 floors the day it carries over to,
--- not the day before it.
local function test_datetime_floor_of_a_24_hour_time_is_the_next_day()
  local db = assert(Sqlite.memory())
  local rows = assert(db:text_rows("SELECT datetime('2025-04-30 24:00:00', 'floor')"))
  local row = rows[1]
  assert(row, "the statement yields a row")
  assert(row:text(1) == "2025-05-01 00:00:00", row:text(1))
  assert(db:close())
end

--- A write that returns rows, closed after its first, commits at the
--- close in autocommit: a failure there is the close's, and the query's.
local function test_a_write_closed_early_answers_its_commit_failure()
  local db = assert(Sqlite.memory())
  assert(db:exec("PRAGMA foreign_keys = ON"))
  assert(db:exec("CREATE TABLE parent (id INTEGER PRIMARY KEY); " ..
      "CREATE TABLE child (parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)"))
  local q = assert(db:query("INSERT INTO child VALUES (1), (2) RETURNING parent_id"))
  assert(q:read())
  local closed, why = q:close()
  assert(not closed and tostring(why):find("FOREIGN KEY", 1, true) ~= nil)
  assert(q:failure() == why)
  assert(#assert(db:rows("SELECT parent_id FROM child")) == 0)
  -- One read to its end commits at its last step, and closes clean.
  assert(db:run("INSERT INTO parent VALUES (1)"))
  local whole = assert(db:query("INSERT INTO child VALUES (1) RETURNING parent_id"))
  for _ in whole:each() do end
  assert(whole:close())
  assert(db:close())
end
