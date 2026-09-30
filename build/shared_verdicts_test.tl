--- The cache `COSMIC_VERDICT_CACHE` names, read and written in this
--- process through [`build.shared_verdicts`]: what it tells a run none of
--- whose lookups stood, and a verdict kept by its declared key alone.
--- build/shared_verdicts_tool_test.tl holds the runs of `cosmic test`
--- that share their verdicts through it.

local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local shared_verdicts = require("build.shared_verdicts")

--- A run none of whose lookups stood is told what the cache held: its
--- rows, those of the tests it looked up, and the digests every key of
--- it holds; an empty cache says nothing.
local function test_a_cache_that_answers_nothing_says_what_it_holds(tmp: string)
  local path = tmp .. "/cache/verdicts.db"
  local cache = assert(shared_verdicts.open(path))
  local empty = assert(shared_verdicts.census(cache, {}))
  assert(empty.rows == 0 and empty.of_tests == 0)
  assert(shared_verdicts.unmatched(path, 3, empty, {}) == nil, "an empty cache said something")
  local kept: {shared_verdicts.Kept} = {}
  for i, test in ipairs({ "a_test.tl test_a", "a_test.tl test_b", "b_test.tl test_c" }) do
    kept[#kept + 1] = { key = "k" .. i, test = test, hits = "", elapsed_ns = 1 }
  end
  assert(shared_verdicts.settle(cache, "first", { kept = kept, used = {}, failed = {} },
    Time.now_ns()))
  local census = assert(shared_verdicts.census(cache, { ["a_test.tl test_a"] = true,
    ["a_test.tl test_b"] = true, ["c_test.tl test_d"] = true }))
  assert(census.rows == 3 and census.of_tests == 2, census.rows .. " " .. census.of_tests)
  local line = assert(shared_verdicts.unmatched(path, 3, census,
    { { "host", "abab" }, { "runtime", "cdcd" } }))
  assert(line:find("none of 3 tests looked up stood", 1, true), line)
  assert(line:find("holds 3 rows, 2 of them of those tests: none under the keys this run reached", 1, true), line)
  assert(line:find("host abab, runtime cdcd", 1, true), line)
  assert(shared_verdicts.unmatched(path, 0, census, {}) == nil, "no lookup, yet a line")
  local other = assert(shared_verdicts.census(cache, { ["c_test.tl test_d"] = true }))
  local unreached = assert(shared_verdicts.unmatched(path, 1, other, {}))
  assert(unreached:find("0 of them of those tests: no other run reached them", 1, true), unreached)
  shared_verdicts.close(cache)
end

--- A census names the key parts the cache's rows were kept under, the
--- most rows first: a run's own, stamped on each row it keeps, and a
--- row from before the column, which names none until a run stands on
--- it, whose key holds the same parts again.
local function test_a_census_names_the_parts_the_rows_were_kept_under(tmp: string)
  local path = tmp .. "/cache/verdicts.db"
  local cache = assert(shared_verdicts.open(path))
  assert(shared_verdicts.census_line((assert(shared_verdicts.held(cache)))) ==
    "test: census: no rows")
  shared_verdicts.close(cache)
  -- As a cache from before the column, holding one row.
  local db = assert(Sqlite.open(path, true))
  assert(db:exec("DROP TABLE declared_v1"))
  assert(db:exec("CREATE TABLE declared_v1 (key TEXT PRIMARY KEY, test TEXT NOT NULL, " ..
    "hits BLOB NOT NULL, elapsed_ns INTEGER NOT NULL, used_ns INTEGER NOT NULL, " ..
    "origin TEXT NOT NULL)"))
  assert(db:exec("INSERT INTO declared_v1 VALUES ('old', 'a_test.tl test_a', " ..
    "deflate(''), 1, " .. Time.now_ns() .. ", 'before')"))
  assert(db:close())
  cache = assert(shared_verdicts.open(path))
  assert(shared_verdicts.declared(cache, "old") ~= nil, "the earlier row went")
  local now = shared_verdicts.named({ { "runtime", "r1" }, { "harness", "e1-00000000-t60000" } })
  assert(now == "runtime r1, harness e1-00000000-t60000", now)
  local kept: {shared_verdicts.Kept} = {}
  for i = 1, 2 do
    kept[i] = { key = "k" .. i, test = "b_test.tl test_" .. i, hits = "", elapsed_ns = 1 }
  end
  assert(shared_verdicts.settle(cache, "first", { parts = now, kept = kept, used = {},
    failed = {} }, Time.now_ns()))
  assert(shared_verdicts.census_line((assert(shared_verdicts.held(cache)))) ==
    "test: census: 2 rows under runtime r1, harness e1-00000000-t60000; 1 row under no parts named")
  -- Stood on, the earlier row is stamped; a named one keeps its parts.
  assert(shared_verdicts.settle(cache, "second", { parts = "runtime r2, harness e2-00000000-t60000",
    kept = {}, used = { "old", "k1" }, failed = {} }, Time.now_ns()))
  local held = assert(shared_verdicts.held(cache))
  assert(#held == 2 and held[1].rows == 2 and held[1].parts == now, held[1].parts)
  assert(held[2].rows == 1 and held[2].parts == "runtime r2, harness e2-00000000-t60000", held[2].parts)
  shared_verdicts.close(cache)
end

--- A verdict is kept by its declared key alone (build/declared_key.tl),
--- with no reads to check it by: found under that key, freshened by a
--- run that relies on it, and taken out by one that fails under it. A
--- cache from before the map has the map made, and the tables
--- observation-keyed runs shared left as they were.
local function test_a_verdict_is_kept_by_its_key_alone(tmp: string)
  local path = tmp .. "/cache/verdicts.db"
  local cache = assert(shared_verdicts.open(path))
  shared_verdicts.close(cache)
  -- As a cache from before the map: an earlier table, and none of its.
  local db = assert(Sqlite.open(path, true))
  assert(db:exec("DROP TABLE declared_v1"))
  assert(db:exec("CREATE TABLE verdicts_v4 (key TEXT PRIMARY KEY)"))
  assert(db:close())
  cache = assert(shared_verdicts.open(path))
  local tables = assert(Sqlite.text_rows(cache.db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name"))
  assert(#tables == 2 and tables[1][1] == "declared_v1" and tables[2][1] == "verdicts_v4",
    "an earlier format's table was dropped: " .. tostring(#tables))
  assert(shared_verdicts.declared(cache, "declared") == nil)
  assert(shared_verdicts.settle(cache, "first", { kept = { {
    key = "declared", test = "suite/t_test.tl test_t", hits = "suite/t_test.tl\t1,2,5\n",
    elapsed_ns = 7 } }, used = {}, failed = {} }, Time.now_ns()))
  local found = assert(shared_verdicts.declared(cache, "declared"))
  assert(found.elapsed_ns == 7 and found.hits == "suite/t_test.tl\t1,2,5\n", found.hits)
  -- Relied on long after it was written, it stays; unrelied, it goes.
  local later = Time.now_ns() + 29 * 24 * 3600 * 1000000000
  assert(shared_verdicts.settle(cache, "second", { kept = {}, used = { "declared" },
    failed = {} }, later))
  assert(shared_verdicts.declared(cache, "declared") ~= nil, "a verdict relied on went")
  assert(shared_verdicts.settle(cache, "second", { kept = {}, used = {}, failed = {} },
    later + 31 * 24 * 3600 * 1000000000))
  assert(shared_verdicts.declared(cache, "declared") == nil, "an unrelied verdict stayed")
  assert(shared_verdicts.settle(cache, "first", { kept = { { key = "declared",
    test = "suite/t_test.tl test_t", hits = "", elapsed_ns = 1 } }, used = {}, failed = {} },
    Time.now_ns()))
  assert(shared_verdicts.settle(cache, "second", { kept = {}, used = {},
    failed = { "declared" } }, Time.now_ns()))
  assert(shared_verdicts.declared(cache, "declared") == nil, "a failure kept it")
  shared_verdicts.close(cache)
end
