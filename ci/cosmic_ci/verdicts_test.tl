local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Verdicts = require("cosmic_ci.verdicts")

--- [`Verdicts.command`], its answer as three values.
local function verdicts_command(argv: {string}, env: {string:string}): integer, string, string
  local command = Verdicts.command(argv, env)
  return command.code, command.out, command.err
end

local s <const> = 1000000000

--- A cache of the shape build/shared_verdicts.tl keeps, in its
--- write-ahead mode: a row of `declared_v1` used at each of `used` (in
--- seconds), each with a few KB of hits, as the lines a test hit are;
--- a row of an older format's table (`verdicts_v3`) used long before;
--- and a table of another shape beside them.
local function cache(path: string, used: {integer})
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(Sqlite.text_rows(db, "PRAGMA journal_mode = WAL"))
  assert(db:exec("CREATE TABLE declared_v1 (key TEXT PRIMARY KEY, test TEXT NOT NULL, " ..
      "hits BLOB NOT NULL, elapsed_ns INTEGER NOT NULL, used_ns INTEGER NOT NULL, " ..
      "origin TEXT NOT NULL); CREATE INDEX declared_v1_by_use ON declared_v1 (used_ns); " ..
      "CREATE TABLE verdicts_v3 (key TEXT PRIMARY KEY, hits BLOB NOT NULL, " ..
      "used_ns INTEGER NOT NULL); CREATE TABLE declared_v9 (key TEXT PRIMARY KEY)"))
  for i, at in ipairs(used) do
    assert(Sqlite.run(db, "INSERT INTO declared_v1 VALUES (?1, ?2, zeroblob(16384), 1, ?3, 'o')",
      { { text = "k" .. tostring(i) }, { text = "t.tl test_" .. tostring(i) }, { integer = at * s } }))
  end
  assert(Sqlite.run(db, "INSERT INTO verdicts_v3 VALUES ('old', zeroblob(16384), 1)"))
  assert(Sqlite.run(db, "INSERT INTO declared_v9 VALUES ('other')"))
  assert(db:close())
end

local function keys(path: string): {string}
  local db = assert(Sqlite.open(path))
  local out: mut {string} = {}
  for _, row in ipairs((assert(Sqlite.text_rows(db,
      "SELECT key FROM declared_v1 UNION ALL SELECT key FROM verdicts_v3 ORDER BY 1")))) do
    out[#out + 1] = row:text(1)
  end
  assert(db:close())
  return out
end

local function outputs(file: string): {string:string}
  local out: mut {string:string} = {}
  for name, value in (Fs.read(file) or ""):gmatch("([%w_]+)=([^\n]*)\n") do out[name] = value end
  return out
end

--- Future/unknown formats stay intact; supported declared rows still trim.
local function test_trim_keeps_unknown_formats_and_reports_them(tmp: string)
  local path = tmp .. "/verdicts.db"
  cache(path, { 999, 1000, 1001 })
  local code, out, err = verdicts_command({ "1000" },
    { COSMIC_VERDICT_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
  assert(code == 0 and err:find("kept tables", 1, true) ~= nil, out .. err)
  local left = keys(path)
  assert(table.concat(left, ",") == "k2,k3,old", table.concat(left, ","))
  assert(#(outputs(tmp .. "/output")["digest"] or "") == 64)
end

local function test_no_run_reached_and_whole_keep_all_rows(tmp: string)
  local path = tmp .. "/verdicts.db"
  cache(path, { 1, 2 })
  for _, since in ipairs({ "1000", "whole" }) do
    local code, out, err = verdicts_command({ since },
      { COSMIC_VERDICT_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
    assert(code == 0, out .. err)
    assert(table.concat(keys(path), ",") == "k1,k2,old")
    assert(#(outputs(tmp .. "/output")["digest"] or "") == 64)
  end
end

local function test_corrupt_active_file_suppresses_the_entire_save_set(tmp: string)
  local path = tmp .. "/verdicts.db"
  local bytes = string.rep("not a database ", 512)
  assert(Fs.write(path, bytes))
  cache(tmp .. "/fixtures.db", { 1, 6 })
  assert(Fs.write(tmp .. "/fixtures.db.corrupt-123", "retired"))
  for _, since in ipairs({ "5", "whole" }) do
    local code, _, err = verdicts_command({ since },
      { COSMIC_VERDICT_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
    assert(code == 0 and err ~= "")
    assert(Fs.read(path) == bytes)
    assert(Fs.stat(tmp .. "/output") == nil)
  end
  assert(Fs.stat(tmp .. "/fixtures.db.corrupt-123") == nil)
end

local function test_digest_depends_on_rows_not_usage_stamps(tmp: string)
  local digests: mut {string} = {}
  for i, used in ipairs({ { 1, 6 }, { 1, 9 }, { 1, 6, 7 } }) do
    local dir = tmp .. "/" .. tostring(i)
    assert(Fs.mkdirs(dir))
    cache(dir .. "/verdicts.db", used)
    local code, out, err = verdicts_command({ "5" },
      { COSMIC_VERDICT_CACHE = dir .. "/verdicts.db", GITHUB_OUTPUT = dir .. "/output" })
    assert(code == 0, out .. err)
    digests[#digests + 1] = assert(outputs(dir .. "/output")["digest"])
  end
  assert(digests[1] == digests[2] and digests[1] ~= digests[3])
end

local function test_no_cache_is_created_or_named_by_a_digest(tmp: string)
  for _, path in ipairs({ "0", "relative", tmp .. "/absent/verdicts.db" }) do
    local code, out, err = verdicts_command({ "5" },
      { COSMIC_VERDICT_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
    assert(code == 0 and err == "" and out:find("nothing to trim", 1, true) ~= nil, out .. err)
  end
  assert(#assert(Fs.list(tmp)) == 0)
  for _, since in ipairs({ "soon", "-1", "9223372037", "1.5" }) do
    assert(verdicts_command({ since }, { COSMIC_VERDICT_CACHE = tmp .. "/v.db" }) == 2)
  end
end

--- A cache holding only build/shared_verdicts.tl's `stores_v1`: the
--- digest of a closure store's bytes by its address, one row used at
--- each of `used` (in seconds), addressed `a<i>`.
local function stores(path: string, used: {integer})
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE stores_v1 (address TEXT PRIMARY KEY, digest TEXT NOT NULL, " ..
      "used_ns INTEGER NOT NULL); CREATE INDEX stores_v1_by_use ON stores_v1 (used_ns)"))
  for i, at in ipairs(used) do
    assert(Sqlite.run(db, "INSERT INTO stores_v1 VALUES (?1, 'd', ?2)",
      { { text = "a" .. tostring(i) }, { integer = at * s } }))
  end
  assert(db:close())
end

--- The addresses `path`'s `stores_v1` holds, with each used_ns in
--- seconds, in address order.
local function addresses(path: string): string
  local db = assert(Sqlite.open(path))
  local out: mut {string} = {}
  for _, row in ipairs((assert(Sqlite.text_rows(db,
      "SELECT address, used_ns / 1000000000 FROM stores_v1 ORDER BY address")))) do
    out[#out + 1] = table.concat(row:texts(), " ")
  end
  assert(db:close())
  return table.concat(out, "\n")
end

--- The digests of closure stores are trimmed as verdicts are: a leg
--- keeps those its run relied on.
local function test_store_digests_are_trimmed_as_verdicts_are(tmp: string)
  local ours = tmp .. "/ours"
  assert(Fs.mkdirs(ours))
  stores(ours .. "/verdicts.db", { 100, 1000 })
  local env = { COSMIC_VERDICT_CACHE = ours .. "/verdicts.db" }
  local code, out, err = verdicts_command({ "1000" }, env)
  assert(code == 0 and err == "", out .. err)
  assert(addresses(ours .. "/verdicts.db") == "a2 1000", addresses(ours .. "/verdicts.db"))
end
