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
  local db = assert(Sqlite.open(path, { writable = true }))
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

local function outputs(file: string): {string:string}
  local out: {string:string} = {}
  for name, value in (Fs.read(file) or ""):gmatch("([%w_]+)=([^\n]*)\n") do out[name] = value end
  return out
end

--- Future/unknown formats stay intact; supported declared rows still trim.
local function test_trim_keeps_unknown_formats_and_reports_them(tmp: string)
  local path = tmp .. "/verdicts.db"
  cache(path, { 999, 1000, 1001 })
  local code, out, err = Verdicts.command({ "1000" },
    { COSMIC_VERDICT_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
  assert(code == 0 and err:find("kept tables", 1, true), out .. err)
  local left = keys(path)
  assert(table.concat(left, ",") == "k2,k3,old", table.concat(left, ","))
  assert(#(outputs(tmp .. "/output").digest or "") == 64)
end

local function test_no_run_reached_and_whole_keep_all_rows(tmp: string)
  local path = tmp .. "/verdicts.db"
  cache(path, { 1, 2 })
  for _, since in ipairs({ "1000", "whole" }) do
    local code, out, err = Verdicts.command({ since },
      { COSMIC_VERDICT_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
    assert(code == 0, out .. err)
    assert(table.concat(keys(path), ",") == "k1,k2,old")
    assert(#(outputs(tmp .. "/output").digest or "") == 64)
  end
end

local function test_corrupt_active_file_suppresses_the_entire_save_set(tmp: string)
  local path = tmp .. "/verdicts.db"
  local bytes = string.rep("not a database ", 512)
  assert(Fs.write(path, bytes))
  cache(tmp .. "/fixtures.db", { 1, 6 })
  assert(Fs.write(tmp .. "/fixtures.db.corrupt-123", "retired"))
  for _, since in ipairs({ "5", "whole" }) do
    local code, _, err = Verdicts.command({ since },
      { COSMIC_VERDICT_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
    assert(code == 0 and err ~= "")
    assert(Fs.read(path) == bytes)
    assert(Fs.stat(tmp .. "/output") == nil)
  end
  assert(Fs.stat(tmp .. "/fixtures.db.corrupt-123") == nil)
end

local function test_digest_depends_on_rows_not_usage_stamps(tmp: string)
  local digests: {string} = {}
  for i, used in ipairs({ { 1, 6 }, { 1, 9 }, { 1, 6, 7 } }) do
    local dir = tmp .. "/" .. i
    assert(Fs.mkdirs(dir))
    cache(dir .. "/verdicts.db", used)
    local code, out, err = Verdicts.command({ "5" },
      { COSMIC_VERDICT_CACHE = dir .. "/verdicts.db", GITHUB_OUTPUT = dir .. "/output" })
    assert(code == 0, out .. err)
    digests[i] = outputs(dir .. "/output").digest
    assert(digests[i] ~= nil)
  end
  assert(digests[1] == digests[2] and digests[1] ~= digests[3])
end

local function test_no_cache_is_created_or_named_by_a_digest(tmp: string)
  for _, path in ipairs({ "0", "relative", tmp .. "/absent/verdicts.db" }) do
    local code, out, err = Verdicts.command({ "5" },
      { COSMIC_VERDICT_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
    assert(code == 0 and err == "" and out:find("nothing to trim", 1, true), out .. err)
  end
  assert(#assert(Fs.list(tmp)) == 0)
  for _, since in ipairs({ "soon", "-1", "9223372037", "1.5" }) do
    assert(Verdicts.command({ since }, { COSMIC_VERDICT_CACHE = tmp .. "/v.db" }) == 2)
  end
end

--- The rows of `path`'s `declared_v1`, a line each: key, test and
--- used_ns (in seconds), in key order.
local function rows(path: string): string
  local db = assert(Sqlite.open(path))
  local out: {string} = {}
  for _, row in ipairs((assert(Sqlite.text_rows(db,
      "SELECT key, test, used_ns / 1000000000 FROM declared_v1 ORDER BY key")))) do
    out[#out + 1] = table.concat(row, " ")
  end
  assert(db:close())
  return table.concat(out, "\n")
end

--- The verdicts of the merge queue's run ahead are added to this run's
--- as a union: each row this run's cache has no row of under the key,
--- stamped used by no run, so the trim keeps only those this run
--- reaches; a row it holds already is kept as it is; nothing is made
--- that neither held; and a second merge of the same file adds nothing.
local function test_a_merge_adds_the_rows_ahead_as_a_union(tmp: string)
  local ahead, ours = tmp .. "/ahead", tmp .. "/ours"
  assert(Fs.mkdirs(ahead) and Fs.mkdirs(ours))
  cache(ours .. "/verdicts.db", { 500, 600 })
  cache(ahead .. "/verdicts.db", { 700, 800, 900 })
  -- Ahead's k1 is another test's, which must not replace ours.
  local db = assert(Sqlite.open(ahead .. "/verdicts.db", { writable = true }))
  assert(Sqlite.run(db, "UPDATE declared_v1 SET test = 'ahead.tl' WHERE key = 'k1'"))
  assert(Sqlite.run(db, "INSERT INTO declared_v9 VALUES ('theirs')"))
  assert(db:close())
  local env = { COSMIC_VERDICT_CACHE = ours .. "/verdicts.db" }
  local code, out, err = Verdicts.merge({ ahead }, env)
  assert(code == 0 and err == "", err)
  assert(out:find("added 1 row to declared_v1, 1 row to declared_v9, 0 rows to verdicts_v3; ", 1, true) ~= nil, out)
  local want = "k1 t.tl test_1 500\nk2 t.tl test_2 600\nk3 t.tl test_3 0"
  assert(rows(ours .. "/verdicts.db") == want, rows(ours .. "/verdicts.db"))
  code, out, err = Verdicts.merge({ ahead }, env)
  assert(code == 0 and err == "" and out:find("added 0 rows to declared_v1, 0 rows to declared_v9", 1, true) ~= nil,
    out .. err)
  assert(rows(ours .. "/verdicts.db") == want, rows(ours .. "/verdicts.db"))
  -- A trim after a run that reached none of them takes them out.
  code, out = Verdicts.command({ "550" }, env)
  assert(code == 0 and rows(ours .. "/verdicts.db") == "k2 t.tl test_2 600", out)
end

--- Where this run restored no cache of the name, the merge makes it,
--- with the tables and indexes the run ahead's declares; a table of
--- another shape, or one without a primary key to tell a held row by,
--- is left as it is and said so.
local function test_a_merge_makes_what_is_missing_and_leaves_another_shape(tmp: string)
  local ahead, ours = tmp .. "/ahead", tmp .. "/ours/sub"
  assert(Fs.mkdirs(ahead))
  cache(ahead .. "/checked.db", { 700 })
  local code, out, err = Verdicts.merge({ ahead }, { COSMIC_VERDICT_CACHE = ours .. "/verdicts.db" })
  assert(code == 0 and err == "", out .. err)
  assert(rows(ours .. "/checked.db") == "k1 t.tl test_1 0", rows(ours .. "/checked.db"))
  assert(not Fs.exists(ours .. "/verdicts.db"), "the merge made a cache the run ahead had none of")
  local db = assert(Sqlite.open(ours .. "/checked.db"))
  local indexes = assert(Sqlite.text_rows(db, "SELECT name FROM sqlite_schema WHERE type = 'index' AND " ..
      "name = 'declared_v1_by_use'"))
  assert(#indexes == 1, "the index was not made")
  assert(db:close())

  db = assert(Sqlite.open(ahead .. "/checked.db", { writable = true }))
  assert(db:exec("CREATE TABLE declared_v7 (key TEXT, x INTEGER); INSERT INTO declared_v7 VALUES ('a', 1); " ..
      "ALTER TABLE declared_v1 ADD COLUMN extra TEXT; INSERT INTO declared_v1 (key, test, hits, elapsed_ns, " ..
      "used_ns, origin) VALUES ('k9', 't', x'00', 1, 1, 'o')"))
  assert(db:close())
  code, out, err = Verdicts.merge({ ahead }, { COSMIC_VERDICT_CACHE = ours .. "/verdicts.db" })
  assert(code == 0 and err == "verdicts-merge: " .. ahead .. "/checked.db: left as they are: " ..
      "declared_v1 (another shape), declared_v7 (no primary key)\n", err)
  assert(rows(ours .. "/checked.db") == "k1 t.tl test_1 0", rows(ours .. "/checked.db"))
end

--- A merge fails no run: with no cache named or none in DIR it does
--- nothing, and a file ahead that is no database is said so and
--- leaves this run's cache as it was; only a missing DIR fails it.
local function test_a_merge_does_nothing_it_is_not_given(tmp: string)
  local ahead, ours = tmp .. "/ahead", tmp .. "/ours"
  assert(Fs.mkdirs(ahead) and Fs.mkdirs(ours))
  for _, env in ipairs({ {} as {string:string}, { COSMIC_VERDICT_CACHE = "0" } }) do
    local code, out, err = Verdicts.merge({ ahead }, env)
    assert(code == 0 and err == "" and out:find("nothing to merge", 1, true) ~= nil, out .. err)
  end
  local env = { COSMIC_VERDICT_CACHE = ours .. "/verdicts.db" }
  local code, out, err = Verdicts.merge({ ahead }, env)
  assert(code == 0 and err == "" and out:find("holds no cache", 1, true) ~= nil, out .. err)
  code, out, err = Verdicts.merge({}, env)
  assert(code == 2 and out == "" and err:find("usage", 1, true) ~= nil, err)
  cache(ours .. "/verdicts.db", { 500 })
  assert(Fs.write(ahead .. "/verdicts.db", string.rep("not a database at all ", 512)))
  code, out, err = Verdicts.merge({ ahead }, env)
  assert(code == 0 and out == "" and err:find("nothing merged", 1, true) ~= nil, out .. err)
  assert(rows(ours .. "/verdicts.db") == "k1 t.tl test_1 500", rows(ours .. "/verdicts.db"))
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
      { { text = "a" .. i }, { integer = at * s } }))
  end
  assert(db:close())
end

--- The addresses `path`'s `stores_v1` holds, with each used_ns in
--- seconds, in address order.
local function addresses(path: string): string
  local db = assert(Sqlite.open(path))
  local out: {string} = {}
  for _, row in ipairs((assert(Sqlite.text_rows(db,
      "SELECT address, used_ns / 1000000000 FROM stores_v1 ORDER BY address")))) do
    out[#out + 1] = table.concat(row, " ")
  end
  assert(db:close())
  return table.concat(out, "\n")
end

--- The digests of closure stores are trimmed and merged as verdicts
--- are: a leg keeps those its run relied on, and takes those of the run
--- ahead in the queue, stamped used by no run.
local function test_store_digests_are_trimmed_and_merged_as_verdicts_are(tmp: string)
  local ahead, ours = tmp .. "/ahead", tmp .. "/ours"
  assert(Fs.mkdirs(ahead) and Fs.mkdirs(ours))
  stores(ours .. "/verdicts.db", { 100, 1000 })
  local env = { COSMIC_VERDICT_CACHE = ours .. "/verdicts.db" }
  local code, out, err = Verdicts.command({ "1000" }, env)
  assert(code == 0 and err == "", out .. err)
  assert(addresses(ours .. "/verdicts.db") == "a2 1000", addresses(ours .. "/verdicts.db"))
  stores(ahead .. "/verdicts.db", { 700, 800, 900 })
  code, out, err = Verdicts.merge({ ahead }, env)
  assert(code == 0 and err == "" and
      out:find("added 2 rows to stores_v1", 1, true) ~= nil, out .. err)
  assert(addresses(ours .. "/verdicts.db") == "a1 0\na2 1000\na3 0",
    addresses(ours .. "/verdicts.db"))
  -- A digest the run ahead kept for an address ours holds otherwise is
  -- warned of, and ours kept.
  local db = assert(Sqlite.open(ahead .. "/verdicts.db", { writable = true }))
  assert(db:exec("UPDATE stores_v1 SET digest = 'e' WHERE address = 'a2'"))
  assert(db:close())
  code, out, err = Verdicts.merge({ ahead }, env)
  assert(code == 0 and err:find("warning: the run ahead kept another digest of a closure " ..
      "store for 1 address of stores_v1", 1, true) ~= nil, out .. err)
  db = assert(Sqlite.open(ours .. "/verdicts.db"))
  local digest = assert(Sqlite.text_rows(db, "SELECT digest FROM stores_v1 WHERE address = 'a2'"))
  assert(db:close())
  assert(digest[1][1] == "d", digest[1][1])
end
