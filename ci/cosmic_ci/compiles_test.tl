local Compiles = require("cosmic_ci.compiles")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- The current supported compile format, independent of candidate imports.
local function cache(path: string, used: {integer})
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:rows("PRAGMA journal_mode = WAL"))
  assert(db:exec("CREATE TABLE compiled_v2 (key TEXT PRIMARY KEY, lua BLOB NOT NULL, " ..
      "bytecode BLOB NOT NULL, refs BLOB NOT NULL, digest TEXT NOT NULL, size INTEGER NOT NULL, " ..
      "used_ns INTEGER NOT NULL)"))
  for i, at in ipairs(used) do
    assert(db:run("INSERT INTO compiled_v2 VALUES (?1, zeroblob(65536), x'', x'', 'd', 65536, ?2)",
      { { text = "k" .. tostring(i) }, { integer = at * 1000000000 } }))
  end
  assert(db:close())
end

--- [`Compiles.command`], what it returns as three values.
local function trimmed(argv: {string}, env: {string:string}): integer, string, string
  local command = Compiles.command(argv, env)
  return command.code, command.out, command.err
end

local function keys(path: string): string
  local db = assert(Sqlite.open(path))
  local out: mut {string} = {}
  for _, row in ipairs((assert(db:rows("SELECT key FROM compiled_v2 ORDER BY key")))) do
    out[#out + 1] = row:text(1)
  end
  assert(db:close())
  return table.concat(out, ",")
end

local function test_trim_uses_seconds_and_publishes_only_complete_outputs(tmp: string)
  local path, restored = tmp .. "/cache.db", tmp .. "/restored.db"
  cache(restored, { 1, 1 })
  cache(path, { 999, 1000, 1001 })
  local code, out, err = trimmed({ "1000", restored },
    { COSMIC_BUILD_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
  assert(code == 0 and err == "", out .. err)
  assert(not assert(Fs.status(path .. "-wal")).exists and not assert(Fs.status(path .. "-shm")).exists)
  assert(keys(path) == "k2,k3")
  local output = assert(Fs.read(tmp .. "/output"))
  assert(output == "digest=2269c56821c2698f2d587c7bc30d964a6f7b44d9e434a8b63628bea32b772056\nfresh=1\n", output)
  assert(not assert(Fs.status(restored)).exists)
end

local function test_missing_cache_stays_missing_and_snapshot_is_cleaned(tmp: string)
  local restored = tmp .. "/restored.db"
  cache(restored, { 1 })
  local code, out, err = trimmed({ "5", restored },
    { COSMIC_BUILD_CACHE = tmp .. "/missing/cache.db", GITHUB_OUTPUT = tmp .. "/output" })
  assert(code == 0 and err == "", out .. err)
  assert(not assert(Fs.status(tmp .. "/missing")).exists and not assert(Fs.status(restored)).exists)
  assert(not assert(Fs.status(tmp .. "/output")).exists)
  code, out, err = trimmed({ "5" }, {})
  assert(code == 0 and err == "" and out:find("nothing to trim", 1, true) ~= nil)
end

local function test_unreadable_active_cache_is_retained_and_never_saved(tmp: string)
  local path, restored = tmp .. "/cache.db", tmp .. "/restored.db"
  local bytes = string.rep("not a database ", 512)
  assert(Fs.write(path, bytes))
  cache(restored, { 1 })
  local code, _, err = trimmed({ "5", restored },
    { COSMIC_BUILD_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
  assert(code == 0 and err ~= "", err)
  assert(assert(Fs.read(path)) == bytes and not assert(Fs.status(restored)).exists)
  assert(not assert(Fs.status(tmp .. "/output")).exists)
end

local function test_unknown_format_is_retained_and_fresh_comparison_is_incomplete(tmp: string)
  local path = tmp .. "/cache.db"
  cache(path, { 1, 6 })
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE compiled_v99 (key TEXT PRIMARY KEY, used_ns INTEGER); " ..
      "INSERT INTO compiled_v99 VALUES ('future', 1)"))
  assert(db:close())
  local code, _, err = trimmed({ "5", tmp .. "/absent.db" },
    { COSMIC_BUILD_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
  assert(code == 0 and err ~= "")
  assert(not assert(Fs.status(tmp .. "/output")).exists)
  db = assert(Sqlite.open(path))
  local future = assert(db:rows("SELECT key FROM compiled_v99"))
  assert(assert(future[1]):text(1) == "future")
  assert(db:close())
end

local function test_digest_ignores_usage_stamps_and_snapshot_absence_counts_fresh(tmp: string)
  local digests: mut {string} = {}
  for i, used in ipairs({ { 1, 6 }, { 1, 9 }, { 1, 6, 7 } }) do
    local dir = tmp .. "/" .. tostring(i)
    assert(Fs.mkdirs(dir))
    cache(dir .. "/cache.db", used)
    local code, out, err = trimmed({ "5", dir .. "/absent.db" },
      { COSMIC_BUILD_CACHE = dir .. "/cache.db", GITHUB_OUTPUT = dir .. "/output" })
    assert(code == 0 and err == "", out .. err)
    local output = assert(Fs.read(dir .. "/output"))
    digests[#digests + 1] = assert(output:match("^digest=([0-9a-f]+)\n"))
    assert(output:find("fresh=" .. tostring((#used - 1)) .. "\n", 1, true), output)
  end
  assert(digests[1] == digests[2] and digests[1] ~= digests[3])
end

local function test_invalid_arguments_and_snapshot_aliases_are_not_removed(tmp: string)
  local path = tmp .. "/cache.db"
  cache(path, { 1 })
  assert(Fs.symlink(path, tmp .. "/link"))
  for _, restored in ipairs({ path, tmp .. "/./cache.db", tmp .. "/link", path .. "-wal" }) do
    local code, _, err = trimmed({ "5", restored }, { COSMIC_BUILD_CACHE = path })
    assert(code == 2 and err:find("aliases", 1, true) ~= nil, err)
    assert(keys(path) == "k1")
  end
  for _, since in ipairs({ "soon", "-1", "9223372037", "1.5" }) do
    assert(trimmed({ since }, { COSMIC_BUILD_CACHE = path }) == 2)
  end
  assert(trimmed({ "5", "relative" }, { COSMIC_BUILD_CACHE = path }) == 2)
end

local function test_only_retired_siblings_are_removed(tmp: string)
  local path = tmp .. "/cache.db"
  cache(path, { 6 })
  assert(Fs.write(path .. ".corrupt-123", "broken"))
  assert(Fs.write(path .. ".corrupt-123-wal", "broken"))
  local code, out, err = trimmed({ "5" }, { COSMIC_BUILD_CACHE = path })
  assert(code == 0 and err == "", out .. err)
  assert(out:find("set aside", 1, true))
  assert(not assert(Fs.status(path .. ".corrupt-123")).exists and not assert(Fs.status(path .. ".corrupt-123-wal")).exists)
end
