local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local sys = require("cosmic.sys")
local observations = require("build.filesystem_observations")
local type raw_process = require("cosmic.internal.process")

local type Searcher = function(string): any, any

--- The raw process table the observations stand in for the spawn of,
--- as `require` hands it their loader.
local function raw_process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("build.filesystem_observations")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: the table core/process.h declares
    end
  end
  error("build.filesystem_observations is handed no raw table")
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
  local open = Http.open
  local run = observations.call(function()
    -- A request that could connect is noted, refused or not: the
    -- wrapper cannot tell what answered -- curl takes "http:/host" for
    -- a host as it does "http://host". One naming a scheme curl is not
    -- let speak fails before it connects.
    Http.open("http://127.0.0.1:1/")
    Http.open("HTTP:/127.0.0.1:1/")
    Http.open("ftp://example.invalid/")
    Http.open("Gopher://example.invalid/")
    local scripted = assert(Http.get("http://example.invalid/",
      { script = { "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" } }))
    assert(scripted.status == 200)
  end, nil)
  assert(run.passed, run.message)
  local unkeyable: {string} = {}
  for _, observation in ipairs(run.reads) do
    if observation.kind == "x" then unkeyable[#unkeyable + 1] = observation.path end
  end
  assert(#unkeyable == 2 and unkeyable[1] == "http://127.0.0.1:1/" and
    unkeyable[2] == "HTTP:/127.0.0.1:1/", table.concat(unkeyable, " "))
  assert(Http.open == open, "a wrapper was left installed")
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
