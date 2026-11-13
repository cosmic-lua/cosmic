--- The cache of compiles shared between checkouts
--- (build/shared_compiles.tl), in-process: its key, what it keeps and
--- what it lets go. What a build makes of it, end to end, is in
--- build/shared_compiles_tool_test.tl.

local Array = require("cosmic.array")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local shared_compiles = require("build.shared_compiles")
local Test = require("cosmic.test")
local type importer = require("build.importer")

--- A key names what decides a compile beside the module's own key:
--- each salt moves it, and the same inputs make the same key.
local function test_the_shared_key_moves_with_each_salt()
  local key = shared_compiles.key
  local base = key("k", false, false)
  assert(base == key("k", false, false))
  local others: {string} = {
    key("k2", false, false),
    key("k", true, false),
    key("k", false, true),
    key("k", false, false, "compiled_v3"),
  }
  local seen: mut {string:boolean} = { [base] = true }
  for index, other in ipairs(others) do
    assert(seen[other] ~= true, "salt " .. tostring(index) .. " did not move the key")
    seen[other] = true
  end
  assert(base == key("k", false, false, "compiled_v2"), "the format is not this one's")
end

--- A compile kept comes back whole, bytes, uses and all, and a row no
--- build has used for thirty days goes the next time one is written.
local function test_a_kept_compile_comes_back_whole(tmp: string)
  local path = tmp .. "/cache/cache.db"
  local cache = assert(shared_compiles.open(path))
  local day = 24 * 3600 * 1000000000
  local lua = "return {}\n"
  local bytecode = "\27Lua\0\1\2\255"
  assert(shared_compiles.settle(cache, { kept = {
    { key = "old", lua = lua, bytecode = bytecode, references = {},
      fact_wraps = 0, parameter_checks = 0 },
  }, used = {} }, 1))
  assert(shared_compiles.settle(cache, { kept = {
    { key = "new", lua = lua, bytecode = bytecode, references = {
      { module = "c", member = "Box.value", line = 7 },
      { module = "cosmic.fs", member = "Stat.size", line = 12 },
    }, fact_wraps = 0, parameter_checks = 0 },
  }, used = {} }, 31 * day))
  local found = assert(shared_compiles.look(cache, "new"))
  assert(found.lua == lua and found.bytecode == bytecode)
  assert(#found.references == 2 and found.references[2].module == "cosmic.fs" and
      found.references[2].member == "Stat.size" and found.references[2].line == 12)
  local gone, trouble = shared_compiles.look(cache, "old")
  assert(gone == nil and trouble == "", "a row unused for thirty days was kept")
  shared_compiles.close(cache)
end

--- Past its bound, the cache keeps the rows most lately used: one
--- written long ago but used now stays, and the rows neither written nor
--- used since go.
local function test_past_its_bound_the_least_lately_used_go(tmp: string)
  local cache = assert(shared_compiles.open(tmp .. "/cache/cache.db"))
  local function kept(key: string): shared_compiles.Kept
    return { key = key, lua = "return {}\n", bytecode = "\27Lua", references = {},
      fact_wraps = 0, parameter_checks = 0 }
  end
  for at, key in ipairs({ "k1", "k2", "k3" }) do
    assert(shared_compiles.settle(cache, { kept = { kept(key) }, used = {} }, at))
  end
  local sizes = assert(Sqlite.text_rows(cache.db, "SELECT DISTINCT size FROM compiled_v2"))
  assert(#sizes == 1, "rows of one shape differ in size")
  local size = math.tointeger(tonumber(sizes[1]:text(1))) or 0
  assert(shared_compiles.settle(cache, { kept = { kept("k4") }, used = { "k1" } }, 5, 2 * size))
  local left = assert(Sqlite.text_rows(cache.db, "SELECT key FROM compiled_v2 ORDER BY key"))
  shared_compiles.close(cache)
  local first, second = left[1], left[2]
  assert(#left == 2 and first ~= nil and second ~= nil and first:text(1) == "k1" and second:text(1) == "k4",
    tostring(first and first:text(1)) .. " " .. tostring(second and second:text(1)))
end

--- A real query failure mentioning malformed is not evidence that a
--- database may be renamed while another connection holds its WAL.
local function test_a_query_failure_leaves_other_connections_and_files_alone(tmp: string)
  local path = tmp .. "/cache/cache.db"
  local build = assert(shared_compiles.for_build({ COSMIC_BUILD_CACHE = path }))
  local holder = assert(Sqlite.open(path, { writable = true }))
  assert(holder:exec("DROP TABLE parsed_v1"))
  assert(holder:exec("CREATE VIEW parsed_v1 AS SELECT * FROM missing_malformed_table"))
  local sibling = path .. ".corrupt-older"
  assert(Fs.write(sibling, "earlier evidence"))
  local files = { path, path .. "-wal", path .. "-shm", sibling }
  local inodes: mut {integer} = {}
  for index, file in ipairs(files) do inodes[index] = assert(Fs.stat(file)).ino end
  local bytes = assert(Fs.read(path))
  local wal = assert(Fs.read(path .. "-wal"))
  assert(#build.analyzers({ "hash" }) == 0)
  assert(#build.analyzers({ "hash" }) == 0)
  build.finish()
  build.finish()
  for index, file in ipairs(files) do assert(assert(Fs.stat(file)).ino == inodes[index], file) end
  assert(Fs.read(path) == bytes and Fs.read(path .. "-wal") == wal)
  assert(Fs.read(sibling) == "earlier evidence")
  assert(#assert(Fs.list(Fs.dirname(path))) == 4, "a cache was renamed or replaced")
  assert(holder:exec("CREATE TABLE healthy (value TEXT)"))
  assert(holder:exec("INSERT INTO healthy VALUES ('still usable')"))
  local reader = assert(Sqlite.open(path))
  assert(Array.at(assert(Sqlite.text_rows(reader, "SELECT value FROM healthy")), 1):text(1) == "still usable")
  assert(reader:close())
  assert(holder:close())
  assert(Fs.stat(path .. "-wal") == nil, "the failed build kept a connection open")
end

--- Many modules are compiled in copies of the process, and each comes
--- back as the copy that had it made it: its own Lua and bytecode, its
--- counts. A module no copy made a compile of is nil, for the build to
--- make. Fewer than a copy is worth are not made at once.
local function test_many_compiles_made_at_once_come_back_each_its_own(tmp: string)
  local build = assert(shared_compiles.for_build({ COSMIC_BUILD_CACHE = tmp .. "/cache/cache.db" }))
  local fan = assert(build.fan)
  local due: mut {importer.Module} = {}
  for index = 1, 400 do
    local path = "suite.m" .. tostring(index)
    due[index] = { path = path, file = "suite/m" .. tostring(index) .. ".tl", kind = "module", source = "",
      source_hash = "", requires = {}, tests = {}, inputs = nil, key = "key of " .. path }
  end
  local function make(m: importer.Module): importer.Shared.Compile?
    if m.path == "suite.m7" then return nil end
    return { lua = "-- lua of " .. m.path, bytecode = "bytecode of " .. m.path, references = {},
      fact_wraps = #m.path, parameter_checks = 2 }
  end
  assert(fan({ assert(due[1]), assert(due[2]) }, true, make) == nil, "two modules are the process's own")
  local fanned = fan(due, true, make)
  if fanned == nil then
    Test.skip("this host makes no copy of the process: one processor, or no fork")
  end
  local made = assert(fanned)
  for _, m in ipairs(due) do
    local found = made.look(m)
    if m.path == "suite.m7" then
      assert(found == nil, "a module no copy compiled came back")
    elseif found == nil then
      -- A copy that could not be forked, or ended badly, leaves its modules to the build.
      Test.skip("a copy of the process did not end well on this host")
    else
      assert(found.lua == "-- lua of " .. m.path and found.bytecode == "bytecode of " .. m.path, m.path)
      assert(found.fact_wraps == #m.path and found.parameter_checks == 2 and #found.references == 0)
    end
  end
  assert(made.look({ path = "suite.other", file = "suite/other.tl", kind = "module", source = "", source_hash = "",
    requires = {}, tests = {}, inputs = nil, key = "another key" }) == nil)
  made.close()
  -- What was made at once is this run's alone until the build keeps it.
  assert(not assert(build.known)(assert(due[1]), true))
  build.finish()
end
