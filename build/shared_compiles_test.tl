--- The cache of compiles shared between checkouts
--- (build/shared_compiles.tl), in-process: its key, what it keeps and
--- what it lets go. What a build makes of it, end to end, is in
--- build/shared_compiles_tool_test.tl.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local shared_compiles = require("build.shared_compiles")

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
  local seen: {string:boolean} = { [base] = true }
  for index, other in ipairs(others) do
    assert(not seen[other], "salt " .. index .. " did not move the key")
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
    { key = "old", lua = lua, bytecode = bytecode, references = {} },
  }, used = {} }, 1))
  assert(shared_compiles.settle(cache, { kept = {
    { key = "new", lua = lua, bytecode = bytecode, references = {
      { module = "c", member = "Box.value", line = 7 },
      { module = "cosmic.fs", member = "Stat.size", line = 12 },
    } },
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
    return { key = key, lua = "return {}\n", bytecode = "\27Lua", references = {} }
  end
  for at, key in ipairs({ "k1", "k2", "k3" }) do
    assert(shared_compiles.settle(cache, { kept = { kept(key) }, used = {} }, at))
  end
  local sizes = assert(Sqlite.text_rows(cache.db, "SELECT DISTINCT size FROM compiled_v2"))
  assert(#sizes == 1, "rows of one shape differ in size")
  local size = math.tointeger(tonumber(sizes[1][1])) or 0
  assert(shared_compiles.settle(cache, { kept = { kept("k4") }, used = { "k1" } }, 5, 2 * size))
  local left = assert(Sqlite.text_rows(cache.db, "SELECT key FROM compiled_v2 ORDER BY key"))
  shared_compiles.close(cache)
  assert(#left == 2 and left[1][1] == "k1" and left[2][1] == "k4",
    tostring(left[1] and left[1][1]) .. " " .. tostring(left[2] and left[2][1]))
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
  local inodes: {integer} = {}
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
  assert(assert(Sqlite.text_rows(reader, "SELECT value FROM healthy"))[1][1] == "still usable")
  assert(reader:close())
  assert(holder:close())
  assert(Fs.stat(path .. "-wal") == nil, "the failed build kept a connection open")
end
