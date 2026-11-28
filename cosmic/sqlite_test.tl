--- Benches of cosmic.sqlite in memory: one insert of three values, one select by key, and 1000 rows read. The
--- module's behavior is tested where it is used (cosmic/store_*_test.tl, cosmic/web/session/sqlite_test.tl).
local Bench = require("cosmic.bench")
local Sqlite = require("cosmic.sqlite")

--- A database in memory with an empty table `w` and a table `t` of `rows` rows.
local function database(rows: integer): Sqlite.Handle
  local db = assert(Sqlite.memory())
  assert(db:exec("create table t (id integer primary key, name text, score real)"))
  assert(db:exec("create table w (id integer primary key, name text, score real)"))
  for i = 1, rows do
    assert(db:run("insert into t (id, name, score) values (?, ?, ?)",
      { { integer = i }, { text = "name" .. tostring(i) }, { number = i / 3 } }))
  end
  return db
end

local function bench_run_insert(b: Bench.B)
  local db = database(0)
  b.reset()
  for i = 1, b.n do
    assert(db:run("insert into w (id, name, score) values (?, ?, ?)",
      { { integer = i }, { text = "name" }, { number = 1.5 } }))
  end
end

local function bench_run_insert_plain(b: Bench.B)
  local db = database(0)
  b.reset()
  for i = 1, b.n do
    assert(db:run("insert into w (id, name, score) values (?, ?, ?)", { i, "name", 1.5 }))
  end
end

local function bench_rows_by_key(b: Bench.B)
  local db = database(1000)
  b.reset()
  for i = 1, b.n do
    local rows = assert(db:rows("select name, score from t where id = ?", { { integer = i % 1000 + 1 } }))
    assert(#rows == 1)
  end
end

local function bench_rows_1000(b: Bench.B)
  local db = database(1000)
  b.reset()
  for _ = 1, b.n do
    local rows = assert(db:rows("select id, name, score from t"))
    assert(#rows == 1000)
  end
end

local function bench_query_each_1000(b: Bench.B)
  local db = database(1000)
  b.reset()
  for _ = 1, b.n do
    local q = assert(db:query("select id, name, score from t"))
    local count = 0
    for row in q:each() do
      if row:integer(1) > 0 then count = count + 1 end
    end
    local _, _ = q:close()
    assert(count == 1000)
  end
end
