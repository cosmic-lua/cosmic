local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local observations = require("build.filesystem_observations")
local test = require("build.test")
local type raw_process = require("cosmic.internal.process")
local type Raw = require("cosmic.internal.observations")

local type Searcher = function(string): any, any

--- What `require` hands the observations' loader.
local function raw_tables(): Raw
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("build.filesystem_observations")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as Raw -- cast: the table core/store.c's open_observations makes
    end
  end
  error("build.filesystem_observations is handed no raw table")
end

--- The raw process table the observations stand in for the spawn of.
local function raw_process_table(): raw_process
  return raw_tables().process
end

local function test_round_trips_every_path_byte()
  local path = "a b\n" .. string.char(0) .. "z"
  local decoded = assert(observations.decode(observations.encode({
    { kind = "s", path = path, answer = "" },
  })))
  assert(#decoded == 1)
  assert(decoded[1].kind == "s")
  assert(decoded[1].path == path)
  assert(observations.decode("plain/old/read.txt") == nil)
  assert(observations.key_part("s", "a\nb", "c") ~=
    observations.key_part("s", "a", "b\nc"))
end

local function test_capture_preserves_a_produced_table_and_restores(tmp: string)
  local path = tmp .. "/loaded"
  assert(Fs.write(path, "hello"))
  local original = sys.open
  local produced = { answer = 42 }
  local c = observations.capture(function(): any
    assert(Fs.read(path) == "hello")
    return produced
  end)
  local found = c.reads
  assert(c.ok and c.produced == produced)
  assert(sys.open == original)
  assert(#found == 1 and found[1].kind == "o" and found[1].path == path)
end

local function test_capture_restores_after_an_error()
  local original = sys.open
  local c = observations.capture(function()
    error("expected")
  end)
  assert(not c.ok and tostring(c.produced):find("expected", 1, true) ~= nil)
  assert(sys.open == original)
end

--- Whether `found` notes an open of `path`.
local function opened(found: {observations.Observation}, path: string): boolean
  for _, observation in ipairs(found) do
    if observation.kind == "o" and observation.path == path then return true end
  end
  return false
end

--- SQLite reads a database in C, where no stand-in for `cosmic.sys`
--- sees it: each file it opens or asks after through `cosmic.sqlite`
--- -- the database, one attached to it, its journal -- is noted an open
--- all the same, by every capture running, and by none once they end.
local function test_a_file_sqlite_opens_is_noted(tmp: string)
  local real = assert(sys.realpath(tmp))
  for _, name in ipairs({ "main.db", "attached.db" }) do
    local db = assert(Sqlite.open(tmp .. "/" .. name, true))
    assert(db:exec("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('" .. name .. "')"))
    assert(db:close())
  end
  local inner: observations.Captured
  local outer = observations.capture(function()
    local db = assert(Sqlite.open(tmp .. "/main.db", false))
    inner = observations.capture(function()
      assert(db:exec("ATTACH DATABASE '" .. tmp .. "/attached.db' AS other"))
      local rows = assert(Sqlite.text_rows(db, "SELECT v FROM other.t"))
      assert(rows[1][1] == "attached.db")
    end)
    assert(db:close())
  end)
  assert(outer.ok, tostring(outer.produced))
  assert(inner.ok, tostring(inner.produced))
  assert(opened(outer.reads, real .. "/main.db"))
  assert(opened(outer.reads, real .. "/attached.db"))
  assert(opened(outer.reads, real .. "/attached.db-journal"))
  -- The inner capture began after the main database was opened, and
  -- is handed it, held open still, as it begins.
  assert(opened(inner.reads, real .. "/main.db"))
  assert(opened(inner.reads, real .. "/attached.db"))
  -- A database opened while no capture runs is noted by none: not by
  -- the next one to start.
  local db = assert(Sqlite.open(tmp .. "/main.db", false))
  assert(db:close())
  local after = observations.capture(function() end)
  assert(not opened(after.reads, real .. "/main.db"))
end

--- A database a connection opened before the capture began, and holds
--- open still, may be read at any page during it: the capture notes it
--- an open as it begins, so what the test reads of it is keyed by its
--- bytes, and other contents key the verdict otherwise. Once closed, it
--- is handed to no capture.
local function test_a_database_opened_before_the_capture_is_keyed_by_its_contents(tmp: string)
  local real = assert(sys.realpath(tmp))
  local path = real .. "/held.db"
  local writer = assert(Sqlite.open(path, true))
  assert(writer:exec("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('one')"))
  local db = assert(Sqlite.open(path, false))
  -- One whose open failed is not held.
  local missing, _ = Sqlite.open(real .. "/missing.db", false)
  assert(missing == nil)
  local function key(): string
    local c = observations.capture(function()
      assert(Sqlite.text_rows(db, "SELECT v FROM t"))
    end)
    assert(c.ok, tostring(c.produced))
    assert(opened(c.reads, path), "the held database was not noted")
    return test.verdict_key(real, {}, "mod.tl name", "modkey", "runtime", c.reads, {}).key
  end
  local before = key()
  assert(key() == before)
  local held = observations.capture(function() end)
  assert(not opened(held.reads, real .. "/missing.db"))
  assert(writer:exec("UPDATE t SET v = 'two'"))
  assert(key() ~= before, "a held database's contents are not in the key")
  assert(writer:close())
  assert(db:close())
  local after = observations.capture(function() end)
  assert(not opened(after.reads, path))
end

--- A runner's own connection's file, excluded, is handed to no capture
--- for being held, though one it opens again is noted; one opened after
--- the exclusion is handed over.
local function test_a_file_excluded_is_not_handed_over(tmp: string)
  local real = assert(sys.realpath(tmp))
  local own = assert(Sqlite.open(real .. "/own.db", true))
  assert(own:exec("CREATE TABLE t (v TEXT)"))
  observations.exclude_held_files()
  local later = assert(Sqlite.open(real .. "/later.db", true))
  local c = observations.capture(function()
    assert(Sqlite.text_rows(own, "SELECT v FROM t"))
  end)
  assert(c.ok, tostring(c.produced))
  assert(not opened(c.reads, real .. "/own.db"))
  assert(opened(c.reads, real .. "/later.db"))
  local again = observations.capture(function()
    local db = assert(Sqlite.open(real .. "/own.db", false))
    assert(db:close())
  end)
  assert(opened(again.reads, real .. "/own.db"))
  assert(own:close())
  assert(later:close())
end

--- A file SQLite fails to open is a read too, whose answer is that it
--- is not there.
local function test_a_missing_database_sqlite_looked_for_is_noted(tmp: string)
  local real = assert(sys.realpath(tmp))
  local c = observations.capture(function()
    local db, trouble = Sqlite.open(tmp .. "/missing.db", false)
    assert(db == nil and trouble ~= "")
  end)
  assert(c.ok, tostring(c.produced))
  assert(opened(c.reads, real .. "/missing.db"))
end

--- A connection `cosmic.sqlite` opens reads the clock through the VFS
--- that observes its files, which passes the question to the default
--- one: `julianday('now')` answers rather than ending the process.
local function test_a_connection_tells_the_time()
  local memory = assert(Sqlite.memory())
  local rows = assert(Sqlite.text_rows(memory, "SELECT julianday('now') > 2460000"))
  assert(memory:close())
  assert(rows[1][1] == "1")
end

local function test_join_deduplicates_only_identical_observations()
  local first: {observations.Observation} = {
    { kind = "s", path = "config", answer = "old" },
    { kind = "s", path = "config", answer = "old" },
  }
  local joined = observations.join(first, {
    { kind = "s", path = "config", answer = "old" },
    { kind = "s", path = "config", answer = "new" },
    { kind = "d", path = "assets", answer = "listing" },
  })
  assert(#joined == 3)
  assert(joined[1].answer == "old" and joined[2].answer == "new")
  assert(joined[3].answer == "listing")
  assert(#first == 2)
end

local function test_captures_answers_when_the_query_occurs(tmp: string)
  local path = tmp .. "/file"
  assert(Fs.write(path, "x"))
  local run = observations.call(function()
    assert(sys.stat(path))
    assert(Fs.write(path, "xx"))
  end, nil)
  assert(run.passed, run.message)
  assert(run.reads[1].answer ~= observations.stat_answer(path))

  local directory_run = observations.call(function()
    assert(sys.readdir(tmp))
    assert(Fs.write(tmp .. "/added", ""))
  end, nil)
  assert(directory_run.passed, directory_run.message)
  assert(directory_run.reads[1].answer ~= observations.directory_answer(tmp))
end

local function test_records_stat_directory_and_open_queries(tmp: string)
  assert(Fs.write(tmp .. "/file", "contents"))
  local run = observations.call(function()
    assert(Fs.exists(tmp .. "/missing") == false)
    assert(Fs.list(tmp))
    assert(Fs.read(tmp .. "/file"))
  end, nil)
  assert(run.passed, run.message)
  local found = run.reads
  assert(found[1].kind == "s" and found[1].path == tmp .. "/missing")
  assert(found[2].kind == "d" and found[2].path == tmp)
  assert(found[3].kind == "o" and found[3].path == tmp .. "/file")
end

local function test_stat_answer_changes_for_deletion_and_metadata(tmp: string)
  local path = tmp .. "/file"
  assert(Fs.write(path, "same bytes"))
  local before = observations.stat_answer(path)
  assert(sys.chmod(path, 0x180))
  local changed = observations.stat_answer(path)
  assert(changed ~= before)
  assert(Fs.remove(path))
  assert(observations.stat_answer(path) ~= changed)
end

local function test_directory_answer_changes_for_an_added_entry(tmp: string)
  local before = observations.directory_answer(tmp)
  assert(Fs.write(tmp .. "/new", ""))
  assert(observations.directory_answer(tmp) ~= before)
end

local function test_restores_all_wrappers_after_an_error()
  local open, stat, readdir = sys.open, sys.stat, sys.readdir
  local run = observations.call(function() error("deliberate") end, nil)
  assert(not run.passed and run.message:find("deliberate", 1, true) ~= nil, run.message)
  assert(sys.open == open)
  assert(sys.stat == stat)
  assert(sys.readdir == readdir)
end

--- `key_part` hex-encodes both the path and the answer; these literals
--- pin the encoding for the bytes most likely to break a lookup-table
--- rewrite of it: NUL, newline, DEL, and 0xff, plus a multibyte UTF-8
--- path, none of which are ASCII letters or digits.
local function test_key_part_matches_known_hex_for_edge_bytes()
  local edges = string.char(0x00, 0x0a, 0x7f, 0xff)
  assert(observations.key_part("s", edges, "") == "s 000a7fff ")
  assert(observations.key_part("o", "", edges) == "o  000a7fff")
  assert(observations.key_part("d", "caf\xc3\xa9", "x") == "d 636166c3a9 78")
end

local function test_getenv_environ_spawn_and_mkdtemp_are_observed()
  local run = observations.call(function()
    Env.get("HOME")
    assert(Fs.mkdtemp("cosmic-observed-"))
    assert(Child.run({ "/bin/sh", "-c", "true" }))
  end, nil)
  assert(run.passed, run.message)
  local kinds: {string:integer} = {}
  for _, observation in ipairs(run.reads) do
    kinds[observation.kind] = (kinds[observation.kind] or 0) + 1
  end
  -- At least the explicit read; `Fs.mkdtemp` and `Child.run` consult
  -- a platform-dependent number of variables themselves.
  assert(kinds.e >= 1)
  assert(kinds.p == 1)
  assert(kinds.m == 1)
end

--- A request over the network is an answer no key can hold; a scripted
--- request connects nowhere and is not one.
local function test_a_network_request_is_an_unkeyable_observation()
  local open, upload = Http.open, Http.upload
  local run = observations.call(function()
    -- A request that could connect is noted, refused or not: the
    -- wrapper cannot tell what answered -- curl takes "http:/host" for
    -- a host as it does "http://host". One naming a scheme curl is not
    -- let speak fails before it connects.
    Http.open("http://127.0.0.1:1/")
    Http.open("HTTP:/127.0.0.1:1/")
    Http.open("ftp://example.invalid/")
    Http.open("Gopher://example.invalid/")
    -- An upload may connect before its first write, so its binding
    -- notes it as it starts, as `open`'s does.
    local up = assert(Http.upload("http://127.0.0.2:1/"))
    assert(up:abort())
    assert(assert(Http.upload("http://example.invalid/", { script = {} })):abort())
    local scripted = assert(Http.get("http://example.invalid/",
      { script = { "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" } }))
    assert(scripted.status == 200)
  end, nil)
  assert(run.passed, run.message)
  local unkeyable: {string} = {}
  for _, observation in ipairs(run.reads) do
    if observation.kind == "x" then unkeyable[#unkeyable + 1] = observation.path end
  end
  assert(#unkeyable == 3 and unkeyable[1] == "http://127.0.0.1:1/" and
    unkeyable[2] == "HTTP:/127.0.0.1:1/" and unkeyable[3] == "http://127.0.0.2:1/",
    table.concat(unkeyable, " "))
  assert(Http.open == open and Http.upload == upload, "a wrapper was left installed")
end

--- A change of directory is a stat of where it went, and a relative
--- path is noted as the absolute one it names from wherever the call
--- was made.
local function test_a_relative_path_is_noted_from_the_working_directory(tmp: string)
  local here = assert(sys.getcwd())
  assert(Fs.mkdirs(tmp .. "/away"))
  local away = assert(sys.realpath(tmp .. "/away"))
  assert(Fs.write(away .. "/f", "x"))
  local chdir = sys.chdir
  local run = observations.call(function()
    assert(sys.chdir(away))
    assert(Fs.read("f") == "x")
    assert(sys.chdir(here))
    local _ = sys.stat("nowhere-relative")
  end, nil)
  assert(run.passed, run.message)
  local noted: {string} = {}
  for _, observation in ipairs(run.reads) do
    assert(observation.kind ~= "x", observation.path)
    if observation.kind == "s" or observation.kind == "o" then
      noted[#noted + 1] = observation.kind .. " " .. observation.path
    end
  end
  local text = table.concat(noted, "\n")
  assert(text:find("s " .. away .. "\n", 1, true), text)
  assert(text:find("o " .. away .. "/f\n", 1, true), text)
  assert(text:find("s " .. here .. "\n", 1, true), text)
  assert(text:find("s " .. here .. "/nowhere-relative", 1, true), text)
  assert(not text:find("o f\n", 1, true), text)
  assert(sys.chdir == chdir, "a wrapper was left installed")
end

--- A process started inside `declared` is noted "h", one outside it "p",
--- and a declaration that did not hold, or one that raised, leaves the
--- run unkeyable or the count of running declarations as it was.
local function test_a_declared_process_is_noted_apart()
  local run = observations.call(function()
    observations.declared("held", function(): boolean
      assert(Child.run({ "/bin/sh", "-c", "exit 0" }))
      return true
    end)
    observations.declared("not held", function(): boolean return false end)
    local raised = pcall(observations.declared, "raised", function(): boolean
      error("boom")
    end)
    assert(not raised)
    assert(Child.run({ "/bin/sh", "-c", "exit 0" }))
  end, nil)
  assert(run.passed, run.message)
  local kinds: {string} = {}
  for _, observation in ipairs(run.reads) do
    if observation.kind == "h" or observation.kind == "p" or observation.kind == "x" then
      kinds[#kinds + 1] = observation.kind .. " " .. observation.path
    end
  end
  local text = table.concat(kinds, "\n")
  assert(text == "h /bin/sh\nx not held\np /bin/sh", text)
end

--- What a confined process ran with, seen from the run's reads: "p"
--- when it ran unconfined.
local function confined_notes(run: observations.Run): string, boolean
  local notes: {string} = {}
  local unconfined = false
  for _, observation in ipairs(run.reads) do
    if observation.kind == "p" then unconfined = true end
    if observation.kind == "u" or observation.kind == "x" or observation.kind == "p" or
        (observation.kind == "e" and observation.path == "\0environ") then
      notes[#notes + 1] = observation.kind .. " " .. observation.path
    end
  end
  return table.concat(notes, "\n") .. "\n", unconfined
end

--- A process a test declared what it needs for has that and the
--- system's own, noted "u" each, and its test's own directory besides,
--- which is not noted and where it starts; a path it was not given is
--- not there at all; the environment it inherits is noted whole.
local function test_a_confined_process_is_noted_by_what_it_was_given(tmp: string)
  local given, own, hidden = tmp .. "/given", tmp .. "/own", tmp .. "/hidden"
  for _, dir in ipairs({ given, own, hidden }) do assert(Fs.mkdirs(dir)) end
  assert(Fs.write(given .. "/f", "in"))
  assert(Fs.write(hidden .. "/f", "secret"))
  local code: integer = nil
  local run = observations.call(function()
    observations.confine({ reads = { given } })
    local r = assert(Child.run({ "/bin/sh", "-c",
      "test -e " .. hidden .. "/f && exit 3; cat " .. given .. "/f > out" }))
    observations.confine(nil)
    code = r.code
  end, nil, { tree = tmp .. "/tree", own = { own } })
  assert(run.passed, run.message)
  local notes, unconfined = confined_notes(run)
  if unconfined then
    -- Unconfined, it sees what it was not given, and says so.
    assert(notes == "p /bin/sh\n", notes)
    assert(code == 3, "an unconfined shell sees everything: " .. tostring(code))
    return
  end
  assert(code == 0, "the confined shell exited " .. tostring(code))
  assert(assert(Fs.read(own .. "/out")) == "in")
  assert(notes:find("u " .. given .. "\n", 1, true), notes)
  assert(notes:find("u /usr\n", 1, true), notes)
  assert(notes:find("e \0environ\n", 1, true), notes)
  assert(not notes:find(own, 1, true), notes)
  assert(not notes:find("p ", 1, true), notes)
  assert(not notes:find("x ", 1, true), notes)
end

--- Where the kernel cannot confine a process it starts as it would have,
--- in the same directory, and the run is noted "p"; so too a process
--- given more paths than a sandbox holds.
local function test_an_unconfinable_process_starts_unconfined(tmp: string)
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own))
  local process = raw_process_table()
  local spawn = process.spawn
  local sandboxed = 0
  process.spawn = function(path: string, argv: {string}, environment: {string:string} | nil,
                       cwd: string | nil, stdin: integer | nil, stdout: integer | nil,
                       stderr: integer | nil, process_group: boolean,
                       fds?: {integer:integer}, sandbox?: raw_process.Sandbox):
                       integer | nil, string, integer
    if sandbox ~= nil then
      sandboxed = sandboxed + 1
      return nil, "Operation not permitted", sys.EPERM
    end
    return spawn(path, argv, environment, cwd, stdin, stdout, stderr, process_group, fds)
  end
  local many: {string} = {}
  for i = 1, 70 do many[i] = tmp .. "/many" .. tostring(i) end
  local run = observations.call(function()
    observations.confine({})
    assert(Child.run({ "/bin/sh", "-c", "pwd > where" }))
    observations.confine({ reads = many })
    assert(Child.run({ "/bin/sh", "-c", "true" }))
    observations.confine(nil)
  end, nil, { tree = tmp .. "/tree", own = { own } })
  process.spawn = spawn
  assert(run.passed, run.message)
  assert(sandboxed == 1, "only the first was tried confined: " .. tostring(sandboxed))
  local notes, _ = confined_notes(run)
  assert(notes == "p /bin/sh\np /bin/sh\n", notes)
  assert(assert(Fs.read(own .. "/where")) == assert(Fs.absolute(own)) .. "\n")
end

--- What a confined process may change outside its test's own directory
--- is no input a key holds, nor is a directory it is handed open.
local function test_a_confined_write_or_descriptor_outside_the_test_is_unkeyable(tmp: string)
  local own, elsewhere = tmp .. "/own", tmp .. "/elsewhere"
  for _, dir in ipairs({ own, elsewhere }) do assert(Fs.mkdirs(dir)) end
  local directory = assert(sys.open(elsewhere, sys.O_RDONLY))
  local run = observations.call(function()
    observations.confine({ writes = { elsewhere } })
    assert(Child.run({ "/bin/sh", "-c", "echo x > " .. elsewhere .. "/f" }))
    assert(Child.run({ "/bin/sh", "-c", "true" }, { fds = { [3] = directory } }))
    observations.confine(nil)
  end, nil, { tree = tmp .. "/tree", own = { own } })
  sys.close(directory)
  assert(run.passed, run.message)
  local notes, unconfined = confined_notes(run)
  assert(assert(Fs.read(elsewhere .. "/f")) == "x\n")
  if unconfined then return end
  assert(notes:find("x " .. elsewhere .. "\n", 1, true), notes)
  assert(notes:find("x fd ", 1, true), notes)
end

--- A confined process's path is keyed by its contents under the tree,
--- and by what `lstat` says of everything beneath it elsewhere, links
--- included; a FIFO beneath it answers from past the root.
local function test_an_unveiled_answer_follows_what_the_path_holds(tmp: string)
  local tree, outside = tmp .. "/tree", tmp .. "/outside"
  for _, dir in ipairs({ tree, outside }) do assert(Fs.mkdirs(dir)) end
  assert(Fs.write(tree .. "/f", "one"))
  assert(Fs.write(outside .. "/f", "one"))
  local inside = observations.unveiled_answer(tree, tree)
  local beyond = observations.unveiled_answer(outside, tree)
  assert(inside == observations.unveiled_answer(tree, tree), "the same tree answers the same")
  assert(beyond == observations.unveiled_answer(outside, tree))
  -- Named below the tree, as any checkout of it names it.
  assert(inside:sub(1, 6) == "\0tree ", inside)
  assert(beyond:sub(1, 1) == "/", beyond)
  assert(Fs.write(tree .. "/f", "two"))
  assert(observations.unveiled_answer(tree, tree) ~= inside, "contents under the tree")
  assert(Fs.write(outside .. "/f", "three"))
  local rewritten = observations.unveiled_answer(outside, tree)
  assert(rewritten ~= beyond, "a file rewritten outside")
  assert(Fs.symlink("f", outside .. "/link"))
  local linked = observations.unveiled_answer(outside, tree)
  assert(linked ~= rewritten, "a link added outside")
  assert(observations.unveiled_answer(tmp .. "/missing", tree) == "missing")
  assert(observations.unveiled_answer(outside, tree):sub(1, 10) ~= "unkeyable ")
  assert(assert(Child.run({ "/bin/sh", "-c", "mkfifo " .. outside .. "/fifo" })).ok)
  assert(observations.unveiled_answer(outside, tree):sub(1, 10) == "unkeyable ")
  local decoded = assert(observations.decode(observations.encode({
    { kind = "u", path = tree, answer = "" },
  })))
  assert(#decoded == 1 and decoded[1].kind == "u" and decoded[1].path == tree)
end

--- A confined process has a /tmp of its own to write in; a TMPDIR its
--- test chose is kept, and one it inherits but may not change is the
--- test's own directory instead.
-- TODO: run the inherited-TMPDIR case wherever the host sets none, and
-- one with no environment given, once cosmic.sys can set a variable of
-- this process: today it runs only where the host's TMPDIR is set.
local function test_a_confined_process_has_somewhere_to_write(tmp: string)
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own))
  local chosen = own .. "/chosen"
  local inherited = Env.get("TMPDIR")
  local said: {string} = {}
  local run = observations.call(function()
    observations.confine({})
    for _, environment in ipairs({ { PATH = "/usr/bin:/bin" },
        { PATH = "/usr/bin:/bin", TMPDIR = chosen },
        inherited ~= nil and { PATH = "/usr/bin:/bin", TMPDIR = inherited } or nil }) do
      local r = assert(Child.run({ "/bin/sh", "-c",
        "echo x > /tmp/f && cat /tmp/f; echo \"${TMPDIR-unset}\"" },
        { env = environment, stdout = "capture" }))
      said[#said + 1] = assert(r.stdout)
    end
    observations.confine(nil)
  end, nil, { tree = tmp .. "/tree", own = { own } })
  assert(run.passed, run.message)
  local _, unconfined = confined_notes(run)
  if unconfined then return end
  assert(said[1] == "x\nunset\n", said[1])
  assert(said[2] == "x\n" .. chosen .. "\n", said[2])
  if inherited ~= nil and not Fs.within(inherited, own) then
    assert(said[3] == "x\n" .. own .. "\n", said[3])
  end
end

--- A confined process is given the portable cache its environment
--- names by where that leads, which its root holds, not through a link
--- its root does not: a launcher there found no cache and ended, and
--- could not make one. One not made yet is named by where its parent
--- leads, and one named without a link is kept as named. What it leads
--- to is no read a key must place: the run stays keyable.
local function test_a_confined_process_has_its_portable_cache_by_where_it_leads(tmp: string)
  local own = tmp .. "/own"
  local real = own .. "/real/cache"
  assert(Fs.mkdirs(real))
  assert(Fs.write(real .. "/core", "core"))
  assert(Fs.symlink(own .. "/real", tmp .. "/linked"))
  local resolved = assert(sys.realpath(real))
  local said: {string} = {}
  local run = observations.call(function()
    observations.confine({ reads = { real .. "/core" } })
    for _, cache in ipairs({ tmp .. "/linked/cache", resolved, tmp .. "/linked/fresh/cache" }) do
      local r = assert(Child.run({ "/bin/sh", "-c",
        "mkdir -p \"$COSMIC_PORTABLE_CACHE\" && ls \"$COSMIC_PORTABLE_CACHE\"; " ..
        "echo \"$COSMIC_PORTABLE_CACHE\"" },
        { env = { PATH = "/usr/bin:/bin", COSMIC_PORTABLE_CACHE = cache }, stdout = "capture" }))
      said[#said + 1] = assert(r.stdout)
    end
    observations.confine(nil)
  end, nil, { tree = tmp .. "/tree", own = { own } })
  assert(run.passed, run.message)
  local notes, unconfined = confined_notes(run)
  assert(not ("\n" .. notes):find("\nx ", 1, true), notes)
  if unconfined then return end
  assert(said[1] == "core\n" .. resolved .. "\n", said[1])
  assert(said[2] == "core\n" .. resolved .. "\n", said[2])
  local fresh = assert(sys.realpath(own .. "/real")) .. "/fresh/cache"
  assert(said[3] == fresh .. "\n", said[3])
  assert(Fs.is_dir(fresh), "the launcher's cache is made where its name leads")
end

--- A process started with a sandbox of its own that unveils and takes
--- the network is noted by what it was given, as a confined one is; one
--- held only by a pledge is not held to what it reads, and is a "p".
local function test_an_unveiled_sandbox_of_its_own_is_noted_by_what_it_was_given(tmp: string)
  local own, given = tmp .. "/own", tmp .. "/given"
  for _, dir in ipairs({ own, given }) do assert(Fs.mkdirs(dir)) end
  local process = raw_process_table()
  local reads: {string} = { given }
  for _, dir in ipairs({ "/usr", "/bin", "/lib", "/lib64", "/etc" }) do
    if sys.stat(dir) ~= nil then reads[#reads + 1] = dir end
  end
  local ran = true
  local run = observations.call(function()
    local pid, _, errno = process.spawn("/bin/sh", { "sh", "-c", "true" }, nil, "/", nil, nil,
      nil, false, nil, { unveil = { reads = reads, writes = { own } }, offline = true })
    if pid == nil then
      ran = false
      assert(errno ~= nil)
    else
      assert(process.waitpid(pid, false))
    end
    local pledged = process.spawn("/bin/sh", { "sh", "-c", "true" }, nil, nil, nil, nil, nil,
      false, nil, { pledge = {} })
    if pledged ~= nil then assert(process.waitpid(pledged, false)) end
  end, nil, { tree = tmp .. "/tree", own = { own } })
  assert(run.passed, run.message)
  local notes, _ = confined_notes(run)
  if ran then
    assert(notes:find("u " .. given .. "\n", 1, true), notes)
    assert(not notes:find("x /bin/sh", 1, true), notes)
  else
    assert(notes:find("x /bin/sh\n", 1, true), notes)
  end
  assert(notes:find("p /bin/sh\n", 1, true), "a pledge alone: " .. notes)
  assert(not notes:find(own, 1, true), notes)
end

--- A sandbox is noted as the core reads it: raw, so a field a metatable
--- answers for holds nothing; and a path given that leads into /proc
--- or /sys, however spelled, is the host's state.
local function test_an_unveiled_sandbox_is_read_as_the_core_reads_it(tmp: string)
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own))
  local process = raw_process_table()
  local reads: {string} = { "//proc/sys/kernel/random" }
  for _, dir in ipairs({ "/usr", "/bin", "/lib", "/lib64", "/etc" }) do
    if sys.stat(dir) ~= nil then reads[#reads + 1] = dir end
  end
  local run = observations.call(function()
    local hidden = setmetatable({} as {string:any}, { __index = function(_: any, key: string): any
      if key == "unveil" then return { reads = reads } end
      return nil
    end }) as raw_process.Sandbox
    hidden.offline = true
    local pid = process.spawn("/bin/sh", { "sh", "-c", "true" }, nil, "/", nil, nil, nil, false,
      nil, hidden)
    if pid ~= nil then assert(process.waitpid(pid, false)) end
    local given = process.spawn("/bin/sh", { "sh", "-c", "true" }, nil, "/", nil, nil, nil,
      false, nil, { unveil = { reads = reads }, offline = true })
    if given ~= nil then assert(process.waitpid(given, false)) end
  end, nil, { tree = tmp .. "/tree", own = { own } })
  assert(run.passed, run.message)
  local notes, _ = confined_notes(run)
  -- The first holds nothing unveiled, so it is a process like any other.
  assert(notes:find("p /bin/sh\n", 1, true), notes)
  assert(notes:find("x //proc/sys/kernel/random\n", 1, true) or
    notes:find("x /bin/sh\n", 1, true), notes)
  assert(not notes:find("u //proc", 1, true), notes)
end

--- The observation of `kind` of `path` in `found`, or nil.
local function noted(found: {observations.Observation}, kind: string,
                     path: string): observations.Observation | nil
  for _, observation in ipairs(found) do
    if observation.kind == kind and observation.path == path then return observation end
  end
  return nil
end

--- `lstat`, `readlink`, `realpath`, `getcwd` and `executable` are
--- logged by those bindings themselves, whoever calls them: a
--- reference taken before the capture began is observed too, each call
--- noted with what it answered, and none once the capture ends.
local function test_a_query_of_the_syscall_table_is_noted_whoever_made_it(tmp: string)
  local real = assert(sys.realpath(tmp))
  assert(Fs.write(real .. "/f", "x"))
  assert(Fs.symlink("f", real .. "/link"))
  local lstat, readlink, realpath = sys.lstat, sys.readlink, sys.realpath
  local getcwd, executable = sys.getcwd, sys.executable
  local c = observations.capture(function()
    assert(lstat(real .. "/link"))
    assert(readlink(real .. "/link") == "f")
    assert(realpath(real .. "/link") == real .. "/f")
    local missing, _ = lstat(real .. "/missing")
    assert(missing == nil)
    assert(getcwd())
    assert(executable())
  end)
  assert(c.ok, tostring(c.produced))
  local function answer(kind: string, path: string): string
    local found = noted(c.reads, kind, path)
    assert(found ~= nil, kind .. " " .. path .. " is not noted")
    return found.answer
  end
  assert(answer("l", real .. "/link") == observations.lstat_answer(real .. "/link"))
  assert(answer("l", real .. "/link"):find(" link ", 1, true), answer("l", real .. "/link"))
  assert(answer("l", real .. "/missing") == observations.lstat_answer(real .. "/missing"))
  assert(answer("l", real .. "/missing"):sub(1, 6) == "error ")
  assert(answer("k", real .. "/link") == "ok f")
  assert(answer("k", real .. "/link") == observations.readlink_answer(real .. "/link"))
  assert(answer("a", real .. "/link") == "ok " .. real .. "/f")
  assert(answer("a", real .. "/link") == observations.realpath_answer(real .. "/link"))
  -- The working directory is keyed as the run started in it, whatever
  -- it answered.
  assert(answer("c", "") == "")
  assert(answer("b", "") == observations.executable_answer())
  -- The program is keyed by what it is, not where: see `tree_name`.
  assert(answer("b", "") == "ok")
  assert(lstat(real .. "/f"))
  local after = observations.capture(function() end)
  assert(noted(after.reads, "l", real .. "/f") == nil)
end

--- A logged query's relative path is noted as the absolute one it names
--- from the working directory the call was made in, and a query is noted
--- by every capture running when it was made: one made before an inner
--- capture began by the outer one alone.
local function test_a_logged_query_is_noted_by_every_capture_running(tmp: string)
  local real = assert(sys.realpath(tmp))
  local here = assert(sys.getcwd())
  local inner: observations.Captured
  local outer = observations.capture(function()
    local _ = sys.lstat(real .. "/before")
    assert(sys.chdir(real))
    inner = observations.capture(function()
      local _ = sys.readlink("relative")
    end)
    assert(sys.chdir(here))
  end)
  assert(outer.ok, tostring(outer.produced))
  assert(inner.ok, tostring(inner.produced))
  assert(noted(outer.reads, "l", real .. "/before") ~= nil)
  assert(noted(inner.reads, "l", real .. "/before") == nil)
  assert(noted(inner.reads, "k", real .. "/relative") ~= nil)
  assert(noted(outer.reads, "k", real .. "/relative") ~= nil)
end

--- Given the test's own directory, a realpath or an lstat of a path in
--- it is resolved as a stat of one is, but an lstat only as far as its
--- last name: of a link there, it is the test's own, and through one
--- that leads out, it reads where the link leads.
local function test_a_query_of_the_tests_own_directory_is_judged_by_where_it_leads(tmp: string)
  local real = assert(sys.realpath(tmp))
  assert(Fs.write(real .. "/f", "x"))
  assert(Fs.symlink("/", real .. "/out"))
  local resolving: observations.Resolving = { tree = real .. "/tree", own = { tmp, real } }
  local own = observations.call(function()
    assert(sys.realpath(tmp .. "/f"))
    local _ = sys.realpath(tmp .. "/missing")
    assert(sys.lstat(tmp .. "/out"))
  end, nil, resolving)
  assert(own.passed, own.message)
  assert(noted(own.reads, "a", tmp .. "/f") ~= nil)
  for _, observation in ipairs(own.reads) do
    assert(observation.kind ~= "x" and observation.kind ~= "t" and observation.kind ~= "w",
      observation.kind .. " " .. observation.path)
  end
  local out = observations.call(function()
    assert(sys.realpath(tmp .. "/out"))
    local _ = sys.lstat(tmp .. "/out/etc")
  end, nil, resolving)
  assert(out.passed, out.message)
  local link = assert(noted(out.reads, "t", tmp .. "/out"))
  assert(link.answer == "/", link.answer)
  local through = assert(noted(out.reads, "w", tmp .. "/out/etc"))
  assert(through.answer == "/etc", through.answer)
end

--- Every call the observations once stood in for is logged by its
--- binding itself: a reference to it taken before the capture began,
--- as `local open = sys.open`, is observed as the table's own is.
local function test_a_reference_taken_before_the_capture_is_observed(tmp: string)
  local real = assert(sys.realpath(tmp))
  assert(Fs.write(real .. "/f", "x"))
  local open, stat, readdir = sys.open, sys.stat, sys.readdir
  local getenv, environ = sys.getenv, sys.environ
  local mkdir, mkdtemp, chdir = sys.mkdir, sys.mkdtemp, sys.chdir
  local http_open = Http.open
  local here = assert(sys.getcwd())
  local made: string = nil
  local c = observations.capture(function()
    sys.close((assert(open(real .. "/f", sys.O_RDONLY))))
    assert(stat(real .. "/f"))
    assert(readdir(real))
    local _ = getenv("COSMIC_OBSERVED_PROBE")
    assert(environ())
    assert(mkdir(real .. "/made"))
    made = assert(mkdtemp(real .. "/temporary-XXXXXX"))
    assert(chdir(real))
    assert(chdir(here))
    local _, _ = http_open("http://127.0.0.1:1/")
  end)
  assert(c.ok, tostring(c.produced))
  local function answer(kind: string, path: string): string
    local found = noted(c.reads, kind, path)
    assert(found ~= nil, kind .. " " .. path .. " is not noted")
    return found.answer
  end
  assert(answer("o", real .. "/f") == "")
  assert(answer("s", real .. "/f") == observations.stat_answer(real .. "/f"))
  assert(answer("d", real) ~= "")
  assert(answer("e", "COSMIC_OBSERVED_PROBE") == observations.getenv_current("COSMIC_OBSERVED_PROBE"))
  assert(answer("e", "\0environ") == observations.getenv_current("\0environ"))
  assert(answer("m", real .. "/made") == "")
  assert(answer("m", made) == "")
  -- A change of directory is a stat of where it went.
  assert(answer("s", real) == observations.stat_answer(real))
  assert(answer("x", "http://127.0.0.1:1/") == "")
end

--- A directory made, and a change of directory, that failed are no
--- directory of the test's own and no stat: the log keeps only what was
--- made, and a stat of where a change was asked to go whatever it did.
local function test_a_failed_mkdir_is_not_the_tests_own(tmp: string)
  local real = assert(sys.realpath(tmp))
  local c = observations.capture(function()
    assert(not sys.mkdir(real .. "/missing/made"))
    assert(not sys.chdir(real .. "/missing"))
  end)
  assert(c.ok, tostring(c.produced))
  assert(noted(c.reads, "m", real .. "/missing/made") == nil)
  local went = assert(noted(c.reads, "s", real .. "/missing"))
  assert(went.answer:sub(1, 6) == "error ", went.answer)
end

--- The process table's own `spawn`, called past the stand-in for it --
--- here through a stand-in kept after its capture ended -- is logged,
--- and the process noted "p" by the capture running then.
local function test_a_process_started_past_the_stand_in_is_noted()
  local process = raw_process_table()
  local held = process.spawn
  local first = observations.capture(function() held = process.spawn end)
  assert(first.ok, tostring(first.produced))
  local c = observations.capture(function()
    local pid = assert(held("/bin/sh", { "sh", "-c", "exit 0" }, nil, nil, nil, nil, nil, false))
    assert(process.waitpid(pid, false))
  end)
  assert(c.ok, tostring(c.produced))
  assert(noted(c.reads, "p", "/bin/sh") ~= nil)
end

--- The path of a read outside the tree is resolved as the call is made,
--- in C beside its record, not when the capture ends: a test that
--- retargets a link of its own directory after reading through it is
--- keyed by where the link led when it read, each kind of read alike.
local function test_a_read_is_resolved_as_it_is_made(tmp: string)
  local real = assert(sys.realpath(tmp))
  for _, dir in ipairs({ "/one", "/two" }) do
    assert(Fs.mkdirs(real .. dir))
    assert(Fs.write(real .. dir .. "/f", "x"))
  end
  local link = real .. "/own/link"
  assert(Fs.mkdirs(real .. "/own"))
  assert(Fs.symlink(real .. "/one", link))
  local resolving: observations.Resolving = { tree = real .. "/tree", own = { real .. "/own" } }
  local run = observations.call(function()
    sys.close((assert(sys.open(link .. "/f", sys.O_RDONLY))))
    assert(sys.stat(link .. "/f"))
    assert(sys.readdir(link))
    assert(sys.realpath(link .. "/f"))
    assert(sys.lstat(link .. "/f"))
    assert(sys.readlink(link))
    assert(sys.unlink(link))
    assert(Fs.symlink(real .. "/two", link))
  end, nil, resolving)
  assert(run.passed, run.message)
  local function resolved(kind: string, path: string): string
    local found = noted(run.reads, kind, path)
    assert(found ~= nil, kind .. " " .. path .. " is not noted")
    return found.answer
  end
  assert(resolved("t", link .. "/f") == real .. "/one/f")
  assert(resolved("t", link) == real .. "/one")
  assert(resolved("w", link .. "/f") == real .. "/one/f")
  -- A readlink stops short of the link it reads, which is the test's own.
  assert(noted(run.reads, "w", link) == nil)
  for _, observation in ipairs(run.reads) do
    assert(observation.kind ~= "x", observation.path)
  end
end

--- What a path resolved to, as the observations told it before the log
--- resolved it in C: the oracle `observations.resolution` must agree
--- with.
local function resolved_before(path: string, link: boolean): string
  if path:sub(1, 1) ~= "/" then return "" end
  if link then
    local name = Fs.basename(path)
    local parent = Fs.dirname(path)
    if not (path:sub(-1) == "/" or name == "." or name == ".." or name == "" or
        parent == path) then
      local up = resolved_before(parent, false)
      if up == "" then return "" end
      return (up == "/" and "" or up) .. "/" .. name
    end
  end
  local missing: {string} = {}
  local at = path
  while true do
    local real, _ = sys.realpath(at)
    if real ~= nil then
      for i = #missing, 1, -1 do
        real = (real == "/" and "" or real) .. "/" .. missing[i]
      end
      return real
    end
    local parent = Fs.dirname(at)
    if parent == at then return "" end
    missing[#missing + 1] = Fs.basename(at)
    at = parent
  end
end

--- The log resolves a path as the observations did in Teal: through
--- links, a missing name and all after it as written, "." and ".."
--- included, each run of slashes as one, and a link it ends in followed
--- or not.
local function test_a_resolution_is_the_one_the_observations_told(tmp: string)
  local real = assert(sys.realpath(tmp))
  assert(Fs.mkdirs(real .. "/d/e"))
  assert(Fs.write(real .. "/d/f", "x"))
  assert(Fs.symlink(real .. "/d", real .. "/link"))
  assert(Fs.symlink("missing", real .. "/dangling"))
  local long = real .. "/" .. string.rep("n", 200)
  for _ = 1, 25 do long = long .. "/" .. string.rep("n", 200) end
  local paths: {string} = { "/", "//", "", "relative/path", "/nowhere/at/all", tmp,
    tmp .. "/", tmp .. "//d///f", real .. "/link", real .. "/link/", real .. "/link/.",
    real .. "/link/..", real .. "/link/e/../f", real .. "/missing/../d/f", real .. "/d/f/",
    real .. "/d/f/g", real .. "/dangling", real .. "/dangling/x", real .. "/./d/./e",
    real .. "/link//", long, long .. "/../f" }
  for _, path in ipairs(paths) do
    for _, link in ipairs({ false, true }) do
      local told = link and observations.link_resolution(path) or observations.resolution(path)
      local want = resolved_before(path, link)
      assert(told == want, (link and "link " or "") .. path:sub(1, 80) .. ": " ..
        told:sub(1, 80) .. " ~= " .. want:sub(1, 80))
    end
  end
end

--- A test's declaration that it reads stat's times is noted by the
--- capture it is made in, and kept through a stored run's encoding, so
--- the key a later run is looked up under sees it before it runs.
local function test_a_declaration_of_stat_s_times_is_noted_and_kept()
  local run: observations.Run = nil
  -- Every capture running notes it, the one around the test's too.
  local outer = observations.capture(function()
    run = observations.call(function()
      observations.reads_stat_times()
    end, nil)
  end)
  assert(outer.ok, tostring(outer.produced))
  assert(run.passed, run.message)
  local around = false
  for _, observation in ipairs(outer.reads) do
    if observation.kind == "z" then around = true end
  end
  assert(around, "the capture around the test's did not note the declaration")
  local declared = false
  for _, observation in ipairs(run.reads) do
    if observation.kind == "z" then declared = true end
  end
  assert(declared, "the declaration was not noted")
  local back = assert(observations.decode(observations.encode(run.reads)))
  local kept = false
  for _, observation in ipairs(back) do
    if observation.kind == "z" then kept = true end
  end
  assert(kept, "the declaration did not survive encoding")
end
