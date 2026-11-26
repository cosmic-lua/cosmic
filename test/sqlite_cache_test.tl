--- The statements a handle keeps for its SQL to run again: [`Sqlite.Handle.run`], [`Sqlite.Handle.rows`] and
--- [`Sqlite.Handle.map`] take one a release of the same SQL kept ([`raw_sqlite.Handle.prepare_cached_result`]) and give it
--- back when done ([`raw_sqlite.Statement.release`]), rewound and with its bindings cleared.
local Sqlite = require("cosmic.sqlite")
local Failure = require("cosmic.failure")
local type raw_sqlite = require("cosmic.internal.sqlite")

--- A writable database in memory with a table `t (id, name)`.
local function fresh(): Sqlite.Handle
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  return db
end

--- A statement a cached prepare made is the one the next cached prepare of the same SQL takes, after its release:
--- the same SQLite statement, its bindings cleared, so a parameter left unbound reads NULL.
local function test_a_released_statement_is_the_next_one_of_its_sql()
  local db = fresh()
  local connection: raw_sqlite.Handle = db.connection
  local first = connection:prepare_cached_result("SELECT ?1")
  assert(first.code == Sqlite.OK)
  local statement = first.statement
  assert(statement:bind_integer(1, 7))
  assert(statement:step() == "row" and statement:integer(0) == 7)
  statement:release()
  local again = connection:prepare_cached_result("SELECT ?1")
  assert(again.code == Sqlite.OK)
  assert(again.statement:step() == "row" and again.statement:kind(0) == "null", "the binding was cleared")
  again.statement:release()
  -- A statement prepared another way is finalized by release, and a second release does nothing.
  local plain = connection:prepare_result("SELECT 1")
  plain.statement:release()
  plain.statement:release()
  local called, _ = pcall(plain.statement.step, plain.statement)
  assert(not called, "a released plain statement is finalized")
  assert(db:close())
end

--- The SQL is the key, byte for byte: a cached prepare of SQL that holds two statements is refused as the plain one is,
--- whether or not the handle keeps one for a prefix of it.
local function test_a_cached_prepare_refuses_what_a_plain_one_refuses()
  local db = fresh()
  local connection: raw_sqlite.Handle = db.connection
  local one = connection:prepare_cached_result("SELECT 1")
  one.statement:release()
  local called, why = pcall(connection.prepare_cached_result, connection, "SELECT 1; SELECT 2")
  assert(not called and tostring(why):find("more than one statement", 1, true) ~= nil, tostring(why))
  assert(db:close())
end

--- The handle's own calls run the same SQL again and again, and a handle that kept statements still closes.
local function test_a_handle_that_kept_statements_closes()
  local db = fresh()
  for i = 1, 40 do
    assert(db:run("INSERT INTO t (id, name) VALUES (?1, ?2)", { { integer = i }, { text = "n" .. tostring(i) } }))
  end
  for i = 1, 20 do
    -- More SQL than the handle keeps, so the oldest are finalized as new ones come.
    local rows = assert(db:rows("SELECT name FROM t WHERE id = ?1 AND " .. tostring(i) .. " > 0", { { integer = i } }))
    assert(#rows == 1 and assert(rows[1]):text(1) == "n" .. tostring(i))
  end
  local closed, why = db:close()
  assert(closed, tostring(why))
end

--- A statement the handle keeps is prepared again by SQLite when the schema moves under it: a column added after it
--- was kept is read.
local function test_a_kept_statement_reads_the_schema_as_it_is_now()
  local db = fresh()
  assert(db:run("INSERT INTO t (id, name) VALUES (1, 'a')"))
  local before = assert(db:rows("SELECT * FROM t"))
  assert(assert(before[1]):count() == 2)
  assert(db:exec("ALTER TABLE t ADD COLUMN extra INTEGER DEFAULT 9"))
  local after = assert(db:rows("SELECT * FROM t"))
  assert(assert(after[1]):count() == 3 and assert(after[1]):integer(3) == 9)
  assert(db:close())
end

--- A `map` whose projection runs the same SQL again takes a statement of its own, not the one being stepped, and
--- every row is read.
local function test_a_map_that_runs_its_own_sql_again_reads_every_row()
  local db = fresh()
  for i = 1, 3 do
    assert(db:run("INSERT INTO t (id, name) VALUES (?1, 'x')", { { integer = i } }))
  end
  local sql = "SELECT id FROM t ORDER BY id"
  local counts = assert(db:map(sql, nil, function(r: Sqlite.Row): integer
    local inner = assert(db:rows(sql))
    return r:integer(1) * 10 + #inner
  end))
  assert(#counts == 3 and counts[1] == 13 and counts[3] == 33, table.concat(counts, ","))
  assert(db:close())
end

--- A failed step leaves the kept statement usable: a constraint refused once, the same insert with another key runs.
local function test_a_statement_kept_after_a_failure_runs_again()
  local db = fresh()
  local insert = "INSERT INTO t (id, name) VALUES (?1, 'x')"
  assert(db:run(insert, { { integer = 1 } }))
  local ok, why = db:run(insert, { { integer = 1 } })
  assert(not ok and why.code == 19, tostring(why))
  assert(db:run(insert, { { integer = 2 } }))
  local rows = assert(db:rows("SELECT count(*) FROM t"))
  assert(assert(rows[1]):integer(1) == 2)
  assert(db:close())
end

--- A row the core builds keeps each column's kind and value, NULL, an empty blob and an empty text included, and a
--- text row holds every column's bytes as text.
local function test_rows_keep_each_kind()
  local db = fresh()
  local rows = assert(db:rows("SELECT 1, 2.5, 'x', x'00ff', NULL, x'', ''"))
  local row = assert(rows[1])
  assert(row:count() == 7)
  assert(row:integer(1) == 1 and row:number(2) == 2.5 and row:text(3) == "x" and row:blob(4) == "\0\255")
  assert(row:is_null(5) and row:kind(6) == "blob" and row:blob(6) == "" and row:text(7) == "")
  assert(db:close())
end

--- A handle does not close while a statement taken from its cache is held, and closes once it is released.
local function test_a_held_kept_statement_holds_the_close_back()
  local db = fresh()
  local connection: raw_sqlite.Handle = db.connection
  local held = connection:prepare_cached_result("SELECT 1")
  assert(held.code == Sqlite.OK)
  local closed, _ = db:close()
  assert(not closed, "a statement still open holds the connection")
  held.statement:release()
  local now, why = db:close()
  assert(now, tostring(why))
end

--- A raise inside a `map` inside a transaction leaves no statement reading: the transaction rolls back, and a later
--- one commits.
local function test_a_raise_in_a_map_leaves_the_connection_free()
  local db = fresh()
  assert(db:run("INSERT INTO t (id, name) VALUES (1, 'a')"))
  local called, _ = pcall(function()
    local _, _ = db:transact(function(): (true) | (false, Failure)
      local _, _ = db:map("SELECT id FROM t", nil, function(_: Sqlite.Row): integer
        error("stop")
      end)
      return true
    end)
  end)
  assert(not called)
  assert(db:transact(function(): (true) | (false, Failure)
    assert(db:run("INSERT INTO t (id, name) VALUES (2, 'b')"))
    return true
  end))
  local rows = assert(db:rows("SELECT count(*) FROM t"))
  assert(assert(rows[1]):integer(1) == 2)
  assert(db:close())
end

--- A PRAGMA is prepared again each time, since some act as they are prepared: the value read is the one set last.
local function test_a_pragma_reads_what_was_set_last()
  local db = fresh()
  assert(db:run("PRAGMA cache_size = 100"))
  assert(assert(assert(db:rows("PRAGMA cache_size"))[1]):integer(1) == 100)
  assert(db:run("PRAGMA cache_size = 200"))
  assert(assert(assert(db:rows("PRAGMA cache_size"))[1]):integer(1) == 200)
  assert(db:close())
end
