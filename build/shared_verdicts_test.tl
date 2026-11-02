--- The cache `COSMIC_VERDICT_CACHE` names, read and written in this
--- process through [`build.shared_verdicts`]: what it tells a run none of
--- whose lookups stood, and a verdict kept by its declared key alone.
--- build/shared_verdicts_tool_test.tl holds the runs of `cosmic test`
--- that share their verdicts through it.

local Clock = require("cosmic.clock")
local Sqlite = require("cosmic.sqlite")
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
  local kept: mut {shared_verdicts.Kept} = {}
  for i, test in ipairs({ "a_test.tl test_a", "a_test.tl test_b", "b_test.tl test_c" }) do
    kept[#kept + 1] = { key = "k" .. tostring(i), test = test, hits = "", elapsed_ns = 1 }
  end
  assert(shared_verdicts.settle(cache, "first", { kept = kept, used = {}, failed = {} },
    Clock.now_ns()))
  local census = assert(shared_verdicts.census(cache, { ["a_test.tl test_a"] = true,
    ["a_test.tl test_b"] = true, ["c_test.tl test_d"] = true }))
  assert(census.rows == 3 and census.of_tests == 2, tostring(census.rows) .. " " .. tostring(census.of_tests))
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
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("DROP TABLE declared_v1"))
  assert(db:exec("CREATE TABLE declared_v1 (key TEXT PRIMARY KEY, test TEXT NOT NULL, " ..
      "hits BLOB NOT NULL, elapsed_ns INTEGER NOT NULL, used_ns INTEGER NOT NULL, " ..
      "origin TEXT NOT NULL)"))
  assert(db:exec("INSERT INTO declared_v1 VALUES ('old', 'a_test.tl test_a', " ..
      "deflate(''), 1, " .. tostring(Clock.now_ns()) .. ", 'before')"))
  assert(db:close())
  cache = assert(shared_verdicts.open(path))
  assert(shared_verdicts.declared(cache, "old") ~= nil, "the earlier row went")
  local now = shared_verdicts.named({ { "runtime", "r1" }, { "harness", "e1-00000000-t60000" } })
  assert(now == "runtime r1, harness e1-00000000-t60000", now)
  local kept: mut {shared_verdicts.Kept} = {}
  for i = 1, 2 do
    kept[i] = { key = "k" .. tostring(i), test = "b_test.tl test_" .. tostring(i), hits = "", elapsed_ns = 1 }
  end
  assert(shared_verdicts.settle(cache, "first", { parts = now, kept = kept, used = {},
    failed = {} }, Clock.now_ns()))
  assert(shared_verdicts.census_line((assert(shared_verdicts.held(cache)))) ==
      "test: census: 2 rows under runtime r1, harness e1-00000000-t60000; 1 row under no parts named")
  -- Stood on, the earlier row is stamped; a named one keeps its parts.
  assert(shared_verdicts.settle(cache, "second", { parts = "runtime r2, harness e2-00000000-t60000",
    kept = {}, used = { "old", "k1" }, failed = {} }, Clock.now_ns()))
  local held = assert(shared_verdicts.held(cache))
  assert(#held == 2 and held[1].rows == 2 and held[1].parts == now, held[1].parts)
  assert(held[2].rows == 1 and held[2].parts == "runtime r2, harness e2-00000000-t60000", held[2].parts)
  shared_verdicts.close(cache)
end

--- A verdict is kept by its declared key alone (build/declared_key.tl),
--- with no reads to check it by: found under that key, freshened by a
--- run that relies on it, and taken out by one that fails under it. A
--- cache of an earlier format gains the declared_v1 and stores_v1
--- tables, and its own tables are left as they were.
local function test_a_verdict_is_kept_by_its_key_alone(tmp: string)
  local path = tmp .. "/cache/verdicts.db"
  local cache = assert(shared_verdicts.open(path))
  shared_verdicts.close(cache)
  -- As a cache of an earlier format: its table, and no declared_v1.
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("DROP TABLE declared_v1"))
  assert(db:exec("CREATE TABLE verdicts_v4 (key TEXT PRIMARY KEY)"))
  assert(db:close())
  cache = assert(shared_verdicts.open(path))
  local tables = assert(Sqlite.text_rows(cache.db,
    "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name"))
  assert(#tables == 3 and tables[1]:text(1) == "declared_v1" and tables[2]:text(1) == "stores_v1" and
      tables[3]:text(1) == "verdicts_v4", "an earlier format's table was dropped: " .. tostring(#tables))
  assert(shared_verdicts.declared(cache, "declared") == nil)
  assert(shared_verdicts.settle(cache, "first", { kept = { {
    key = "declared", test = "suite/t_test.tl test_t", hits = "suite/t_test.tl\t1,2,5\n",
    elapsed_ns = 7 } }, used = {}, failed = {} }, Clock.now_ns()))
  local found = assert(shared_verdicts.declared(cache, "declared"))
  assert(found.elapsed_ns == 7 and found.hits == "suite/t_test.tl\t1,2,5\n", found.hits)
  -- Relied on long after it was written, it stays; unrelied, it goes.
  local later = Clock.now_ns() + 29 * 24 * 3600 * 1000000000
  assert(shared_verdicts.settle(cache, "second", { kept = {}, used = { "declared" },
    failed = {} }, later))
  assert(shared_verdicts.declared(cache, "declared") ~= nil, "a verdict relied on went")
  assert(shared_verdicts.settle(cache, "second", { kept = {}, used = {}, failed = {} },
    later + 31 * 24 * 3600 * 1000000000))
  assert(shared_verdicts.declared(cache, "declared") == nil, "an unrelied verdict stayed")
  assert(shared_verdicts.settle(cache, "first", { kept = { { key = "declared",
    test = "suite/t_test.tl test_t", hits = "", elapsed_ns = 1 } }, used = {}, failed = {} },
    Clock.now_ns()))
  assert(shared_verdicts.settle(cache, "second", { kept = {}, used = {},
    failed = { "declared" } }, Clock.now_ns()))
  assert(shared_verdicts.declared(cache, "declared") == nil, "a failure kept it")
  shared_verdicts.close(cache)
end

--- The digest of a closure store's bytes is kept by its address: found
--- once a run kept it, freshened by a run that relies on it, and gone
--- once no run has for thirty days. A file whose declared_v1 table has
--- its `parts` but no stores_v1, as an earlier binary made it, gains it.
local function test_a_store_digest_is_kept_by_its_address(tmp: string)
  local path = tmp .. "/cache/verdicts.db"
  local cache = assert(shared_verdicts.open(path))
  shared_verdicts.close(cache)
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("DROP TABLE stores_v1"))
  assert(db:close())
  cache = assert(shared_verdicts.open(path))
  assert(shared_verdicts.store_digest(cache, "address") == nil)
  local now = Clock.now_ns()
  assert(shared_verdicts.settle(cache, "first", { kept = {}, used = {}, failed = {},
    stores = { address = "digest" } }, now))
  assert(shared_verdicts.store_digest(cache, "address") == "digest")
  assert(shared_verdicts.store_digest(cache, "another") == nil)
  local day <const> = 24 * 3600 * 1000000000
  assert(shared_verdicts.settle(cache, "second", { kept = {}, used = {}, failed = {},
    stores = { address = "digest" } }, now + 29 * day))
  assert(shared_verdicts.settle(cache, "third", { kept = {}, used = {}, failed = {} },
    now + 58 * day))
  assert(shared_verdicts.store_digest(cache, "address") == "digest", "a digest relied on went")
  assert(shared_verdicts.settle(cache, "fourth", { kept = {}, used = {}, failed = {} },
    now + 60 * day))
  assert(shared_verdicts.store_digest(cache, "address") == nil, "an unrelied digest stayed")
  shared_verdicts.close(cache)
end

--- The identity and rest of the host a row was reached on are what its
--- parts name, and a cache names the hosts of a rest but for the one
--- asking: not a row that names no host, nor one that names only its
--- rest or its identity, nor the host's own, nor another rest's.
local function test_a_cache_names_the_other_hosts_of_a_rest(tmp: string)
  local named = shared_verdicts.host_of("host kernel aa, host bb, host identity 0f, host rest 1e")
  assert(named.identity == "0f" and named.rest == "1e")
  local none = shared_verdicts.host_of("host kernel aa, host bb, system cc")
  assert(none.identity == nil and none.rest == nil)
  local near = shared_verdicts.host_of("host identity 0f2, the host identity 0e, host rest")
  assert(near.identity == "0f2" and near.rest == nil, "a part is named whole")
  local cache = assert(shared_verdicts.open(tmp .. "/cache/verdicts.db"))
  local kept: mut {shared_verdicts.Kept} = {}
  local owed = { "host kernel aa, host identity 0a, host rest 11",
    "host kernel bb, host identity 0b, host rest 11",
    "host kernel cc, host identity 0c, host rest 22",
    "host kernel dd, host identity 0d",
    "host kernel ee, host rest 11", "" }
  for at, parts in ipairs(owed) do
    kept[#kept + 1] = { key = "k" .. tostring(at), test = "t_test.tl test_" .. tostring(at), hits = "", elapsed_ns = 1 }
    assert(shared_verdicts.settle(cache, "o", { parts = parts, kept = { assert(kept[at]) },
      used = {}, failed = {} }, Clock.now_ns()))
  end
  local others = assert(shared_verdicts.hosts_like(cache, "11", "0a"))
  assert(#others == 1 and others[1] == "0b", table.concat(others, ","))
  local all = assert(shared_verdicts.hosts_like(cache, "11", "ff"))
  assert(#all == 2 and all[1] == "0a" and all[2] == "0b", table.concat(all, ","))
  assert(#assert(shared_verdicts.hosts_like(cache, "33", "0a")) == 0, "another rest")
  shared_verdicts.close(cache)
end

--- A checked run (`cosmic test --check-types`) keeps its verdicts in a file of its own beside the others', unless
--- `COSMIC_VERDICT_CACHE` names one, and that file keeps twice as many rows: its 7900 keys would otherwise share
--- the bound of 8192 with the ordinary suite's.
local function test_a_checked_run_reads_its_own_file(tmp: string)
  local env = { XDG_CACHE_HOME = tmp .. "/cache" }
  local plain = assert(shared_verdicts.location(env))
  local checked = assert(shared_verdicts.location(env, true))
  assert(plain:match("/verdicts/verdicts%.db$") ~= nil, plain)
  assert(checked:match("/verdicts/verdicts%-checked%.db$") ~= nil, checked)
  local named = { XDG_CACHE_HOME = tmp .. "/cache", COSMIC_VERDICT_CACHE = "/somewhere/else.db" }
  assert(shared_verdicts.location(named, true) == "/somewhere/else.db")
  assert(shared_verdicts.location(named) == "/somewhere/else.db")
  assert(shared_verdicts.location({ COSMIC_VERDICT_CACHE = "0" }, true) == nil)
  assert(shared_verdicts.rows_kept(checked) == 16384)
  assert(shared_verdicts.rows_kept("/ci/verdicts/narrowing.db") == 16384)
  assert(shared_verdicts.rows_kept(plain) == 8192)
  assert(shared_verdicts.rows_kept("/ci/verdicts/checked.db") == 8192, "the sanitized core's suite keeps the old bound")
end

--- A file of a checked run's verdicts keeps its rows past the 8192 an ordinary file keeps: what a run owes it is
--- trimmed to `rows_kept` of its own path.
local function test_a_settle_trims_to_the_bound_of_its_file(tmp: string)
  local function rows_after(name: string): integer
    local cache = assert(shared_verdicts.open(tmp .. "/" .. name))
    local kept: mut {shared_verdicts.Kept} = {}
    for i = 1, 8200 do
      kept[#kept + 1] = { key = "k" .. tostring(i), test = "t" .. tostring(i), hits = "", elapsed_ns = 1 }
    end
    assert(shared_verdicts.settle(cache, "origin", { kept = kept, used = {}, failed = {} }, Clock.now_ns()))
    local counted = assert(Sqlite.text_rows(cache.db, "SELECT count(*) FROM declared_v1"))
    shared_verdicts.close(cache)
    return math.tointeger(tonumber(assert(counted[1]):text(1))) or -1
  end
  assert(rows_after("verdicts.db") == 8192, "an ordinary file kept another number")
  assert(rows_after("verdicts-checked.db") == 8200, "a checked file was trimmed to the ordinary bound")
end
