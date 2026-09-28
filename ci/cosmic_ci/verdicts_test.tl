local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Verdicts = require("cosmic_ci.verdicts")

local s <const> = 1000000000

--- A cache of the shape build/shared_verdicts.tl keeps, in its
--- write-ahead mode: a row of `declared_v1` used at each of `used` (in
--- seconds), each with a few KB of hits, as the lines a test hit are;
--- a row of an older format's table (`verdicts_v3`) used long before;
--- and a table of another shape beside them.
local function cache(path: string, used: {integer})
  local db = assert(Sqlite.open(path, true))
  assert(Sqlite.text_rows(db, "PRAGMA journal_mode = WAL"))
  assert(db:exec("CREATE TABLE declared_v1 (key TEXT PRIMARY KEY, test TEXT NOT NULL, " ..
    "hits BLOB NOT NULL, elapsed_ns INTEGER NOT NULL, used_ns INTEGER NOT NULL, " ..
    "origin TEXT NOT NULL); CREATE INDEX declared_v1_by_use ON declared_v1 (used_ns); " ..
    "CREATE TABLE verdicts_v3 (key TEXT PRIMARY KEY, hits BLOB NOT NULL, " ..
    "used_ns INTEGER NOT NULL); CREATE TABLE declared_v9 (key TEXT PRIMARY KEY)"))
  for i, at in ipairs(used) do
    assert(Sqlite.run(db, "INSERT INTO declared_v1 VALUES (?1, ?2, zeroblob(16384), 1, ?3, 'o')",
      { { text = "k" .. i }, { text = "t.tl test_" .. i }, { integer = at * s } }))
  end
  assert(Sqlite.run(db, "INSERT INTO verdicts_v3 VALUES ('old', zeroblob(16384), 1)"))
  assert(Sqlite.run(db, "INSERT INTO declared_v9 VALUES ('other')"))
  assert(db:close())
end

local function keys(path: string): {string}
  local db = assert(Sqlite.open(path))
  local out: {string} = {}
  for _, row in ipairs((assert(Sqlite.text_rows(db,
      "SELECT key FROM declared_v1 UNION ALL SELECT key FROM verdicts_v3 ORDER BY 1")))) do
    out[#out + 1] = row[1]
  end
  assert(db:close())
  return out
end

local function freelist(path: string): integer
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "PRAGMA freelist_count"))
  assert(db:close())
  return math.tointeger(tonumber(rows[1][1])) or -1
end

--- What a leg saves is what its own run relied on or reached: rows
--- under keys an earlier run reached go, an older format's with them,
--- and so does the space they took and the pages the cache's own bound
--- freed; the file keeps no log of its write-ahead mode to be saved.
local function test_a_trim_keeps_only_what_the_run_reached(tmp: string)
  local path = tmp .. "/verdicts.db"
  cache(path, { 100, 100, 100, 999, 1000, 1001 })
  -- As the cache's bound does: rows deleted, their pages kept free.
  local db = assert(Sqlite.open(path, true))
  assert(Sqlite.run(db, "DELETE FROM declared_v1 WHERE key IN ('k2', 'k3')"))
  assert(db:close())
  assert(freelist(path) > 0, "the fixture freed no page")
  local before = assert(Fs.stat(path)).size
  local code, out, err = Verdicts.command({ "1000" }, { COSMIC_VERDICT_CACHE = path })
  assert(code == 0 and err == "", err)
  -- k5 and k6, and the table the trim cannot read by its use.
  assert(out:find("kept 3 used since 1000, removed 3", 1, true) ~= nil, out)
  assert(Fs.stat(path .. "-wal") == nil and Fs.stat(path .. "-shm") == nil,
    "the trim left the cache's log")
  assert(freelist(path) == 0, "the trim left free pages")
  assert(assert(Fs.stat(path)).size <= before - 5 * 16384)
  local left = keys(path)
  assert(#left == 2 and left[1] == "k5" and left[2] == "k6", table.concat(left, ","))
end

--- Every cache the save carries is trimmed -- the portable suite's
--- beside the others' -- but one the run reached none of keeps its
--- rows: its suite did not run, which says nothing of whether the next
--- run needs them.
local function test_a_cache_the_run_never_reached_is_kept_whole(tmp: string)
  cache(tmp .. "/verdicts.db", { 100, 1001 })
  cache(tmp .. "/portable.db", { 100, 200 })
  assert(Fs.write(tmp .. "/notes.txt", "not a cache"))
  local code, out, err = Verdicts.command({ "1000" },
    { COSMIC_VERDICT_CACHE = tmp .. "/verdicts.db" })
  assert(code == 0 and err == "", err)
  assert(out:find("kept 2 used since 1000, removed 2; " .. tmp .. "/verdicts.db", 1, true) ~= nil,
    out)
  assert(out:find("kept all 4, none used since 1000 (no run reached it); " ..
    tmp .. "/portable.db", 1, true) ~= nil, out)
  assert(#keys(tmp .. "/verdicts.db") == 1)
  assert(#keys(tmp .. "/portable.db") == 3)
  assert(Fs.stat(tmp .. "/notes.txt") ~= nil)
end

--- Where the variable names no file, or a directory holding no cache,
--- the command does nothing, and makes nothing; a SINCE that is no
--- count of seconds is the one thing it fails on.
local function test_the_command_trims_nothing_it_is_not_given(tmp: string)
  for _, env in ipairs({ {} as {string:string}, { COSMIC_VERDICT_CACHE = "0" },
      { COSMIC_VERDICT_CACHE = "verdicts.db" },
      { COSMIC_VERDICT_CACHE = tmp .. "/verdicts.db" },
      { COSMIC_VERDICT_CACHE = tmp .. "/missing/verdicts.db" } }) do
    local code, out, err = Verdicts.command({ "5" }, env)
    assert(code == 0 and err == "" and out:find("nothing to trim", 1, true) ~= nil, out .. err)
  end
  assert(#(assert(Fs.list(tmp))) == 0, "the command made a file")
  local code, _, err = Verdicts.command({ "soon" }, { COSMIC_VERDICT_CACHE = tmp .. "/v.db" })
  assert(code == 2 and err:find("SINCE", 1, true) ~= nil, err)
  code, _, err = Verdicts.command({ "-1" }, { COSMIC_VERDICT_CACHE = tmp .. "/v.db" })
  assert(code == 2 and err:find("SINCE", 1, true) ~= nil, err)
end

--- A cache the trim cannot read fails no leg, as it fails no suite: the
--- command says why and removes a file that is no database, so no save
--- carries it on, and still trims the cache beside it; and what the
--- suites set aside as broken goes too.
local function test_the_command_removes_what_is_broken(tmp: string)
  local path = tmp .. "/verdicts.db"
  assert(Fs.write(path, string.rep("not a database at all ", 512)))
  cache(tmp .. "/portable.db", { 999, 1001 })
  assert(Fs.write(tmp .. "/portable.db.corrupt-123", "broken"))
  assert(Fs.write(tmp .. "/portable.db.corrupt-123-wal", "broken"))
  local code, out, err = Verdicts.command({ "1000" }, { COSMIC_VERDICT_CACHE = path })
  assert(code == 0, "status " .. code)
  assert(err:find("verdicts-trim: " .. path, 1, true) ~= nil and
    err:find("removed", 1, true) ~= nil, err)
  assert(Fs.stat(path) == nil, "the corrupt cache is still there")
  assert(out:find("set aside", 1, true) ~= nil, out)
  assert(Fs.stat(tmp .. "/portable.db.corrupt-123") == nil and
    Fs.stat(tmp .. "/portable.db.corrupt-123-wal") == nil)
  assert(#keys(tmp .. "/portable.db") == 1, out)
end
