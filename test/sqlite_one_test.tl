local Sqlite = require("cosmic.sqlite")

--- The first row, as rows reads it, and no more: a query that yields
--- none returns nil alone, and one that fails returns nil and why.
local function test_one_answers_the_first_row_or_none()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT); INSERT INTO t VALUES (1, 'a'), (2, NULL)"))
  local row = assert(db:one("SELECT id, body FROM t ORDER BY id"))
  assert(row:integer(1) == 1 and row:text(2) == "a")
  local null = assert(db:one("SELECT body FROM t WHERE id = ?1", { 2 }))
  assert(null:is_null(1))
  local none, why = db:one("SELECT body FROM t WHERE id = ?1", { 3 })
  assert(none == nil and why == nil)
  local bad, failure = db:one("SELECT nope FROM t")
  assert(bad == nil and failure ~= nil and failure.message:find("no such column", 1, true) ~= nil)
  local short, range = db:one("SELECT ?1, ?2", { 1 })
  assert(short == nil and range ~= nil and range.code == Sqlite.RANGE)
  assert(db:close())
end

--- A query left after its first row is released, so a write the
--- statement would block runs, and the handle closes.
local function test_one_stops_at_the_first_row()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (n); INSERT INTO t VALUES (1), (2), (3)"))
  -- An error in the second row is never reached (no ORDER BY, which
  -- would compute every row before the first).
  local row = assert(db:one("SELECT CASE WHEN n = 1 THEN n ELSE abs(-9223372036854775807 - 1) END FROM t"))
  assert(row:integer(1) == 1)
  assert(db:exec("DROP TABLE t"))
  assert(db:close())
end

--- A write with RETURNING makes every change, and `one` returns its first row;
--- for `one` and for `run`, a failure where it commits (a deferred foreign key) is why, and the
--- write is undone. The same SQL runs again from the handle's cache.
local function test_one_and_run_of_a_write_answer_its_commit()
  local db = assert(Sqlite.memory())
  assert(db:exec("PRAGMA foreign_keys = ON; CREATE TABLE p (id INTEGER PRIMARY KEY); " ..
      "CREATE TABLE c (pid REFERENCES p (id) DEFERRABLE INITIALLY DEFERRED)"))
  local first = assert(db:one("INSERT INTO p VALUES (1), (2), (3) RETURNING id"))
  assert(first:integer(1) == 1)
  assert(assert(db:one("SELECT count(*) FROM p")):integer(1) == 3)
  local row, why = db:one("INSERT INTO c VALUES (99), (98) RETURNING pid")
  assert(row == nil and why ~= nil and why.message:find("FOREIGN KEY", 1, true) ~= nil, tostring(why))
  assert(assert(db:one("SELECT count(*) FROM c")):integer(1) == 0)
  local ran, refused = db:run("INSERT INTO c VALUES (97) RETURNING pid")
  assert(ran == false and refused.message:find("FOREIGN KEY", 1, true) ~= nil, tostring(refused))
  assert(assert(db:one("SELECT count(*) FROM c")):integer(1) == 0)
  local bad, misuse = db:one("SELECT 1; SELECT 2")
  assert(bad == nil and misuse ~= nil and misuse.code == 21, tostring(misuse))
  assert(db:close())
  local ok, _ = pcall(function() local _, _ = db:one("SELECT 1") end)
  assert(not ok, "one on a closed handle raises")
end
