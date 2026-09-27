local Compiles = require("cosmic_ci.compiles")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

--- A cache of the shape build/shared_compiles.tl keeps, in its
--- write-ahead mode, a row used at each of `used` (in seconds), and a
--- table of another shape beside it.
local function cache(path: string, used: {integer})
  local db = assert(Sqlite.open(path, true))
  assert(Sqlite.text_rows(db, "PRAGMA journal_mode = WAL"))
  assert(db:exec("CREATE TABLE compiled_v2 (key TEXT PRIMARY KEY, lua BLOB NOT NULL, " ..
    "used_ns INTEGER NOT NULL); CREATE TABLE compiled_v9 (key TEXT PRIMARY KEY)"))
  for i, at in ipairs(used) do
    assert(Sqlite.run(db, "INSERT INTO compiled_v2 VALUES (?1, zeroblob(65536), ?2)",
      { { text = "k" .. i }, { integer = at * 1000000000 } }))
  end
  assert(Sqlite.run(db, "INSERT INTO compiled_v9 VALUES ('other')"))
  assert(db:close())
end

local function keys(path: string): {string}
  local db = assert(Sqlite.open(path))
  local out: {string} = {}
  for _, row in ipairs((assert(Sqlite.text_rows(db, "SELECT key FROM compiled_v2 ORDER BY key")))) do
    out[#out + 1] = row[1]
  end
  assert(db:close())
  return out
end

--- What a leg saves is what its own run used, and the file shrinks to
--- it: an older run's compiles go, and so does the space they took.
local function test_a_trim_keeps_only_what_the_run_used(tmp: string)
  local path = tmp .. "/cache.db"
  cache(path, { 100, 100, 100, 200 })
  local trimmed = assert(Compiles.trim(path, 200 * 1000000000))
  assert(trimmed.removed == 3, "removed " .. trimmed.removed)
  -- The row used since, and the table the trim cannot read by its use.
  assert(trimmed.kept == 2, "kept " .. trimmed.kept)
  assert(trimmed.after_bytes <= trimmed.before_bytes - 3 * 65536,
    trimmed.before_bytes .. " -> " .. trimmed.after_bytes)
  local left = keys(path)
  assert(#left == 1 and left[1] == "k4")
end

--- Parses are kept as compiles are: a table of the parses' formats
--- (`parsed_v<n>`) keeps only what the run used.
local function test_a_trim_keeps_only_the_parses_the_run_used(tmp: string)
  local path = tmp .. "/cache.db"
  cache(path, { 200 })
  local db = assert(Sqlite.open(path, true))
  assert(db:exec("CREATE TABLE parsed_v1 (analyzer TEXT NOT NULL, source_hash TEXT NOT NULL, " ..
    "mapped INTEGER NOT NULL, rows BLOB NOT NULL, used_ns INTEGER NOT NULL, " ..
    "PRIMARY KEY (analyzer, source_hash, mapped))"))
  for i, at in ipairs({ 100, 100, 200 }) do
    assert(Sqlite.run(db, "INSERT INTO parsed_v1 VALUES ('x', ?1, 0, zeroblob(65536), ?2)",
      { { text = "h" .. i }, { integer = at * 1000000000 } }))
  end
  assert(db:close())
  local trimmed = assert(Compiles.trim(path, 200 * 1000000000))
  assert(trimmed.removed == 2, "removed " .. trimmed.removed)
  assert(trimmed.kept == 3, "kept " .. trimmed.kept)
  db = assert(Sqlite.open(path))
  local left = assert(Sqlite.text_rows(db, "SELECT source_hash FROM parsed_v1"))
  assert(db:close())
  assert(#left == 1 and left[1][1] == "h3")
end

--- The command takes SINCE in seconds, against a cache's nanoseconds: a
--- compile used a second after it stays, one a second before goes; and
--- it leaves no log of the cache's write-ahead mode behind to be saved.
local function test_the_command_trims_by_seconds(tmp: string)
  local path = tmp .. "/cache.db"
  cache(path, { 999, 1001 })
  local before = assert(Fs.stat(path)).size
  local code, out, err = Compiles.command({ "1000" }, { COSMIC_BUILD_CACHE = path })
  assert(code == 0 and err == "", err)
  assert(out:find("kept 2 used since 1000, removed 1", 1, true) ~= nil, out)
  -- Before `keys` reads it: a reader alone leaves the log where it is.
  assert(Fs.stat(path .. "-wal") == nil and Fs.stat(path .. "-shm") == nil,
    "the trim left the cache's log")
  assert(assert(Fs.stat(path)).size < before)
  local left = keys(path)
  assert(#left == 1 and left[1] == "k2")
end

--- Where the variable names no file, or a file not there, the command
--- does nothing, and makes nothing.
local function test_the_command_trims_nothing_it_is_not_given(tmp: string)
  for _, env in ipairs({ {} as {string:string}, { COSMIC_BUILD_CACHE = "0" },
      { COSMIC_BUILD_CACHE = tmp .. "/cache.db" } }) do
    local code, out, err = Compiles.command({ "5" }, env)
    assert(code == 0 and err == "" and out:find("nothing to trim", 1, true) ~= nil, out .. err)
  end
  assert(#(assert(Fs.list(tmp))) == 0, "the command made a file")
  local code, _, err = Compiles.command({ "soon" }, { COSMIC_BUILD_CACHE = tmp .. "/cache.db" })
  assert(code == 2 and err:find("SINCE", 1, true) ~= nil, err)
end

--- A cache the trim cannot read fails no leg, as it fails no build: the
--- command says why and removes a file that is no database, so no save
--- carries it on.
local function test_the_command_removes_a_corrupt_cache(tmp: string)
  local path = tmp .. "/cache.db"
  assert(Fs.write(path, string.rep("not a database at all ", 512)))
  local code, _, err = Compiles.command({ "5" }, { COSMIC_BUILD_CACHE = path })
  assert(code == 0, "status " .. code)
  assert(err:find("compiles-trim: " .. path, 1, true) ~= nil and
    err:find("removed", 1, true) ~= nil, err)
  assert(Fs.stat(path) == nil, "the corrupt cache is still there")
end

--- What the builds set aside as broken beside the cache is removed, so
--- no save carries it from run to run.
local function test_the_command_removes_what_the_builds_set_aside(tmp: string)
  local path = tmp .. "/cache.db"
  cache(path, { 1001 })
  assert(Fs.write(path .. ".corrupt-123", "broken"))
  assert(Fs.write(path .. ".corrupt-123-wal", "broken"))
  assert(Fs.write(tmp .. "/other.db.corrupt-123", "another's"))
  local code, out, err = Compiles.command({ "1000" }, { COSMIC_BUILD_CACHE = path })
  assert(code == 0 and err == "", err)
  assert(out:find("set aside", 1, true) ~= nil, out)
  assert(Fs.stat(path .. ".corrupt-123") == nil and Fs.stat(path .. ".corrupt-123-wal") == nil)
  assert(Fs.stat(tmp .. "/other.db.corrupt-123") ~= nil, "removed another file's")
  assert(#keys(path) == 1)
end
