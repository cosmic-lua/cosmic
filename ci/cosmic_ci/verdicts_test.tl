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

--- What the command says, on standard error, of the fixture's table
--- of another shape, which it keeps whole.
local function unstamped(path: string): string
  return "verdicts-trim: " .. path .. ": kept whole, with no used_ns column to trim by: declared_v9\n"
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
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(Sqlite.run(db, "DELETE FROM declared_v1 WHERE key IN ('k2', 'k3')"))
  assert(db:close())
  assert(freelist(path) > 0, "the fixture freed no page")
  local before = assert(Fs.stat(path)).size
  local code, out, err = Verdicts.command({ "1000" }, { COSMIC_VERDICT_CACHE = path })
  assert(code == 0 and err == unstamped(path), err)
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
  assert(code == 0 and err == unstamped(tmp .. "/portable.db") .. unstamped(tmp .. "/verdicts.db"),
    err)
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

--- A table the trim matches but cannot trim, with no `used_ns` column
--- to trim it by (a format of the tool's it does not know), is kept
--- whole and said so, on standard error, rather than saved from run to
--- run unseen; a cache whose every table it can trim says nothing
--- there.
local function test_a_table_without_its_use_is_kept_whole_and_said_so(tmp: string)
  local path = tmp .. "/verdicts.db"
  cache(path, { 100, 1001 })
  local code, out, err = Verdicts.command({ "1000" }, { COSMIC_VERDICT_CACHE = path })
  assert(code == 0 and err == unstamped(path), err)
  assert(out:find("kept 2 used since 1000, removed 2", 1, true) ~= nil, out)
  local db = assert(Sqlite.open(path, { writable = true }))
  local rows = assert(Sqlite.text_rows(db, "SELECT key FROM declared_v9"))
  assert(#rows == 1 and rows[1][1] == "other", "the table was not kept whole")
  assert(db:exec("DROP TABLE declared_v9"))
  assert(db:close())
  code, out, err = Verdicts.command({ "1000" }, { COSMIC_VERDICT_CACHE = path })
  assert(code == 0 and err == "", err)
  assert(out:find("kept 1 used since 1000, removed 0", 1, true) ~= nil, out)
end

--- The step output the command wrote to `file`, by name.
local function outputs(file: string): {string:string}
  local out: {string:string} = {}
  for name, value in (Fs.read(file) or ""):gmatch("([%w_]+)=([^\n]*)\n") do out[name] = value end
  return out
end

--- The command names what it leaves by a digest of its rows, the tail
--- of the key ci.yml saves them under: a run that reached the same rows
--- as the one before, stamping them again, names the same digest, and
--- so saves nothing new, whatever SQLite made of the file's pages; a
--- run that reached another row names another.
local function test_the_command_names_the_rows_it_keeps_by_a_digest(tmp: string)
  local first, again, other = tmp .. "/a", tmp .. "/b", tmp .. "/c"
  for _, dir in ipairs({ first, again, other }) do assert(Fs.mkdirs(dir)) end
  cache(first .. "/verdicts.db", { 100, 1001, 1002 })
  -- The same rows, used later, in a file that held and lost more.
  cache(again .. "/verdicts.db", { 100, 1600, 1700, 1800 })
  local db = assert(Sqlite.open(again .. "/verdicts.db", { writable = true }))
  assert(Sqlite.run(db, "DELETE FROM declared_v1 WHERE key = 'k4'"))
  assert(db:close())
  cache(other .. "/verdicts.db", { 100, 1001, 1002, 1003 })
  local digests: {string} = {}
  for i, dir in ipairs({ first, again, other }) do
    local file = dir .. "/output"
    local code, out, _ = Verdicts.command({ i == 1 and "1000" or "1001" },
      { COSMIC_VERDICT_CACHE = dir .. "/verdicts.db", GITHUB_OUTPUT = file })
    digests[i] = outputs(file).digest
    assert(code == 0 and digests[i] ~= nil and #digests[i] == 64, out)
    assert(out:find("digest " .. digests[i] .. " of 1 cache", 1, true) ~= nil, out)
  end
  -- Each keeps k2 and k3, and the table it cannot trim.
  assert(digests[1] == digests[2], "the same rows named two digests")
  assert(digests[1] ~= digests[3], "another row named the same digest")
end

--- Given `whole`, as ci.yml's step is where the run failed, the command
--- trims nothing -- a run that stopped short saves what it restored
--- with what it reached -- but still removes what was set aside, and
--- still names the rows by their digest.
local function test_whole_trims_nothing_but_names_a_digest(tmp: string)
  local path = tmp .. "/verdicts.db"
  cache(path, { 100, 1001 })
  assert(Fs.write(path .. ".corrupt-123", "broken"))
  local code, out, err = Verdicts.command({ "whole" },
    { COSMIC_VERDICT_CACHE = path, GITHUB_OUTPUT = tmp .. "/output" })
  assert(code == 0 and err == "", err)
  assert(out:find("kept every row of " .. path, 1, true) ~= nil, out)
  assert(Fs.stat(path .. ".corrupt-123") == nil, "what was set aside is still there")
  assert(#keys(path) == 3, "a row was trimmed")
  assert(#(outputs(tmp .. "/output").digest or "") == 64, "no digest")
end

--- Where there is no cache there is nothing to save, and no digest to
--- name it by.
local function test_no_cache_names_no_digest(tmp: string)
  assert(Fs.mkdirs(tmp .. "/empty"))
  local code, out, _ = Verdicts.command({ "5" },
    { COSMIC_VERDICT_CACHE = tmp .. "/empty/verdicts.db", GITHUB_OUTPUT = tmp .. "/output" })
  assert(code == 0 and out:find("nothing to trim", 1, true) ~= nil, out)
  assert(Fs.stat(tmp .. "/output") == nil, "a digest named nothing")
end

--- A cache whose rows cannot be read, which `whole` leaves, is named
--- by its bytes, and said so: it is saved again rather than taken for
--- a cache of rows saved already.
local function test_a_cache_it_cannot_read_is_digested_by_its_bytes(tmp: string)
  local path = tmp .. "/verdicts.db"
  local digests: {string} = {}
  for i, bytes in ipairs({ "not a database at all ", "nor is this one at all " }) do
    assert(Fs.write(path, string.rep(bytes, 512)))
    local file = tmp .. "/output" .. i
    local code, _, err = Verdicts.command({ "whole" },
      { COSMIC_VERDICT_CACHE = path, GITHUB_OUTPUT = file })
    assert(code == 0 and err:find("digested by its bytes", 1, true) ~= nil, err)
    digests[i] = outputs(file).digest
  end
  assert(digests[1] ~= nil and digests[1] ~= digests[2], "two files named one digest")
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
