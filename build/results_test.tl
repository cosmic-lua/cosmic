local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local results = require("build.results")
local Sqlite = require("cosmic.sqlite")

local function test_a_bench_round_keeps_each_arm_by_its_binary(tmp: string)
  local old, new = tmp .. "/old", tmp .. "/new"
  assert(Fs.write(old, "old bytes"))
  assert(Fs.write(new, "new bytes"))
  local db = assert(results.open(results.path(tmp)))
  local id = assert(results.keep_bench(db, { started_ns = 42, arms = {
    { name = "old", path = old, samples = {
      { bench = "a_test.tl:bench_x", rep = 2, ns_per_op = 20.5, n = 8, bytes = 0 },
      { bench = "a_test.tl:bench_x", rep = 1, ns_per_op = 10.0, n = 8, bytes = 0 } } },
    { name = "new", path = new, samples = { { bench = "a_test.tl:bench_x", rep = 1, ns_per_op = 5.0, n = 16,
      bytes = 64 } } } } }))
  assert(id == "bench-42", id)
  local samples = assert(results.bench_samples(db, id, "old"))
  assert(#samples == 2 and samples[1]!.rep == 1 and samples[1]!.ns_per_op == 10.0 and samples[2]!.ns_per_op == 20.5)
  local newer = assert(results.bench_samples(db, id, "new"))
  assert(#newer == 1 and newer[1]!.n == 16 and newer[1]!.bytes == 64)
  local arms = assert(db:rows("SELECT name, binary FROM arms WHERE round = ?1 ORDER BY name", { { text = id } }))
  assert(arms[2]!:text(1) == "old" and arms[2]!:text(2) == Hash.hex_sha256("old bytes"))
  local round = assert(db:rows("SELECT started_ns, finished_ns FROM rounds WHERE id = ?1", { { text = id } }))
  assert(round[1]!:integer(1) == 42 and round[1]!:integer(2) >= 42)
  local _, _ = db:close()
end

-- A round is kept whole or not at all: a second round of the same start keeps nothing.
local function test_a_round_that_cannot_be_kept_keeps_nothing(tmp: string)
  local binary = tmp .. "/cosmic"
  assert(Fs.write(binary, "bytes"))
  local db = assert(results.open(results.path(tmp)))
  local round: results.Round = { started_ns = 7, arms = { { name = "this", path = binary, samples = {
    { bench = "a_test.tl:bench_x", rep = 1, ns_per_op = 1.0, n = 1, bytes = 0 } } } } }
  assert(results.keep_bench(db, round))
  local id, why = results.keep_bench(db, round)
  assert(id == nil and tostring(why):find("UNIQUE", 1, true) ~= nil, tostring(why))
  local count = assert(db:rows("SELECT count(*) FROM bench_runs"))
  assert(count[1]!:integer(1) == 1)
  local missing, missing_why = results.keep_bench(db, { started_ns = 8, arms = {
    { name = "this", path = tmp .. "/absent", samples = {} } } })
  assert(missing == nil and tostring(missing_why):find("/absent", 1, true) ~= nil, tostring(missing_why))
  local _, _ = db:close()
end

-- The shared tables are a database an eval's rounds can live in too: what only a bench keeps is in a table of its own.
local function test_the_shared_tables_hold_a_round_of_any_kind(tmp: string)
  local db = assert(Sqlite.open(tmp .. "/any.db", { writable = true }))
  assert(db:exec(results.SHARED))
  assert(db:run("INSERT INTO rounds (id, started_ns) VALUES ('eval-1', 1)"))
  assert(db:run("INSERT INTO arms (round, name, binary, path) VALUES ('eval-1', 'cosmic', 'ab', '/bin/cosmic')"))
  local tables = assert(db:rows("SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name"))
  assert(#tables == 2 and tables[1]!:text(1) == "arms" and tables[2]!:text(1) == "rounds")
  local _, _ = db:close()
end
