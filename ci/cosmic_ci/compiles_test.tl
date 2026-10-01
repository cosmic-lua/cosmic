local Compiles = require("cosmic_ci.compiles")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local SqliteOpen = require("cosmic_ci.sqlite_open")

--- A cache of the shape build/shared_compiles.tl keeps, in its
--- write-ahead mode, a row used at each of `used` (in seconds), and a
--- table of another shape beside it.
local function cache(path: string, used: {integer})
  local db = assert(SqliteOpen.writable(path))
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

--- What the command says, on standard error, of the fixture's table
--- of another shape, which it keeps whole.
local function unstamped(path: string): string
  return "compiles-trim: " .. path .. ": kept whole, with no used_ns column to trim by: compiled_v9\n"
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
  assert(#trimmed.unstamped == 1 and trimmed.unstamped[1] == "compiled_v9",
    table.concat(trimmed.unstamped, ","))
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
  local db = assert(SqliteOpen.writable(path))
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
  assert(code == 0 and err == unstamped(path), err)
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
  assert(code == 0 and err == unstamped(path), err)
  assert(out:find("set aside", 1, true) ~= nil, out)
  assert(Fs.stat(path .. ".corrupt-123") == nil and Fs.stat(path .. ".corrupt-123-wal") == nil)
  assert(Fs.stat(tmp .. "/other.db.corrupt-123") ~= nil, "removed another file's")
  assert(#keys(path) == 1)
end

--- The command names what it keeps by a digest of its rows, the tail
--- of the key ci.yml saves it under: the same compiles, used again
--- later, name the same digest, so a run that compiled nothing new
--- saves nothing new; another compile names another.
local function test_the_command_names_the_rows_it_keeps_by_a_digest(tmp: string)
  local digests: {string} = {}
  for i, used in ipairs({ { 999, 1001 }, { 1500, 1600 }, { 1500, 1600, 1700 } }) do
    local dir = tmp .. "/" .. i
    assert(Fs.mkdirs(dir))
    cache(dir .. "/cache.db", used)
    local code, out, _ = Compiles.command({ i == 1 and "1000" or "1550" },
      { COSMIC_BUILD_CACHE = dir .. "/cache.db", GITHUB_OUTPUT = dir .. "/output" })
    digests[i] = (assert(Fs.read(dir .. "/output"))):match("^digest=(%x+)\n$")
    assert(code == 0 and digests[i] ~= nil and #digests[i] == 64, out)
    assert(out:find("digest " .. digests[i], 1, true) ~= nil, out)
  end
  -- The first keeps k2 of two; the second k2 of two, used later.
  assert(digests[1] == digests[2], "the same compiles named two digests")
  assert(digests[1] ~= digests[3], "another compile named the same digest")
end

--- Given a copy of what the leg restored, the command also names how
--- many of the compiles it keeps that copy lacks (`fresh`), what a
--- branch's save turns on, and removes the copy, which no save carries:
--- a compile restored and used again is not fresh, one made since is.
local function test_the_command_counts_the_compiles_not_restored(tmp: string)
  local path = tmp .. "/cache.db"
  local restored = tmp .. "/restored.db"
  -- Restored k1 and k2; the run used k2 again, and made k3 and k4.
  cache(restored, { 999, 999 })
  cache(path, { 999, 1001, 1002, 1003 })
  local code, out, err = Compiles.command({ "1000", restored },
    { COSMIC_BUILD_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
  assert(code == 0 and err == unstamped(path), err)
  assert(out:find("2 compiles not in what was restored", 1, true) ~= nil, out)
  local output = assert(Fs.read(tmp .. "/output"))
  assert(output:match("\nfresh=2\n$") ~= nil, output)
  assert(Fs.stat(restored) == nil, "the copy of what was restored is still there")
  -- Nothing restored: every compile kept is fresh, the fixture's table
  -- of another shape's too.
  local again = tmp .. "/again.db"
  cache(again, { 1001, 1002 })
  assert(Fs.write(tmp .. "/output", ""))
  code, out, err = Compiles.command({ "1000", restored },
    { COSMIC_BUILD_CACHE = again, GITHUB_OUTPUT = tmp .. "/output" })
  assert(code == 0 and (assert(Fs.read(tmp .. "/output"))):match("\nfresh=3\n$") ~= nil, out .. err)
end

--- Fresh compiles are counted against the restored table of the same
--- format alone: a restored table of another format holds no compile
--- this one's builds could take.
local function test_fresh_compiles_are_counted_by_format(tmp: string)
  local path = tmp .. "/cache.db"
  local restored = tmp .. "/restored.db"
  local db = assert(SqliteOpen.writable(restored))
  assert(db:exec("CREATE TABLE compiled_v1 (key TEXT PRIMARY KEY); INSERT INTO compiled_v1 VALUES ('k1')"))
  assert(db:close())
  cache(path, { 1001 })
  -- compiled_v2's k1, and compiled_v9's `other`, which no restored
  -- table of its name holds.
  assert(Compiles.fresh(path, restored) == 2)
  assert(Compiles.fresh(path, tmp .. "/absent.db") == 2)
end

--- A RESTORED that is no absolute path is refused, as a SINCE that is
--- no count of seconds is; where there is no cache to trim, the copy
--- still goes.
local function test_the_command_takes_restored_as_an_absolute_path(tmp: string)
  local code, _, err = Compiles.command({ "5", "restored.db" }, { COSMIC_BUILD_CACHE = tmp .. "/cache.db" })
  assert(code == 2 and err:find("RESTORED", 1, true) ~= nil, err)
  local restored = tmp .. "/restored.db"
  cache(restored, { 1 })
  local out: string
  code, out, err = Compiles.command({ "5", restored }, { COSMIC_BUILD_CACHE = tmp .. "/cache.db" })
  assert(code == 0 and err == "" and out:find("nothing to trim", 1, true) ~= nil, out .. err)
  assert(Fs.stat(restored) == nil, "the copy of what was restored is still there")
end
