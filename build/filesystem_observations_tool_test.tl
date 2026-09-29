--- The cases of build/filesystem_observations_test.tl whose process
--- is confined in a root of its own: what the observer notes of it, and
--- what it is given to write.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local confine = require("build.confine")
local observations = require("build.filesystem_observations")
local stand_in = require("build.stand_in")
local type raw_process = require("cosmic.internal.process")

-- TODO: declare /proc for Linux alone once a declaration can name a
-- host path per platform (a `host` entry for Linux and one for macOS):
-- macOS has no /proc, so there this declares a path that is not there,
-- which gives and keys nothing but says what the tests need wrongly.
--- What the observer is tested observing: the environment, processes it
--- confines, and /proc, where the stand-in a test starts finds itself;
--- `nests`, since the processes it confines have roots of their own;
--- and `tool`, since a process confined is given the program (the TODO
--- above build.confine's `forbid_running`).
Test.needs{
  host = { "/proc" },
  env = { "*" },
  processes = true,
  tool = true,
  nests = true,
}

--- A stand-in program built under `tmp` (build/stand_in.tl), which runs
--- the script its first argument holds: a static executable that reads
--- only itself (and /proc, where it finds itself), so one confined
--- needs nothing of the system's own.
local function probe_in(tmp: string): string
  return (assert(stand_in.build(tmp .. "/stand-in")))
end

local type Searcher = function(string): any, any

--- The raw process table build.confine stands in for the spawn of.
local function raw_process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("build.confine")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: the table core/process.h defines
    end
  end
  error("build.confine is handed no raw table")
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

--- A process a test declared what it needs for has that and what every
--- process has -- /dev/null and /proc, and the system's own where its
--- worker has them -- noted "u" each, and its test's own directory
--- besides, which is not noted and where it starts; a path it was not
--- given is not there at all; the environment it inherits is noted
--- whole.
local function test_a_confined_process_is_noted_by_what_it_was_given(tmp: string)
  local probe = probe_in(tmp)
  local given, own, hidden = tmp .. "/given", tmp .. "/own", tmp .. "/hidden"
  for _, dir in ipairs({ given, own, hidden }) do assert(Fs.mkdirs(dir)) end
  assert(Fs.write(given .. "/f", "in"))
  assert(Fs.write(hidden .. "/f", "secret"))
  local code: integer = nil
  local run = observations.call(function()
    confine.confine({ reads = { given, probe } })
    local r = assert(Child.run({ probe,
      "exists " .. hidden .. "/f 3; copy " .. given .. "/f out" }))
    confine.confine(nil)
    code = r.code
  end, nil, { tree = tmp .. "/tree", own = { own } })
  assert(run.passed, run.message)
  local notes, unconfined = confined_notes(run)
  if unconfined then
    -- Unconfined, it sees what it was not given, and says so.
    assert(notes == "p " .. probe .. "\n", notes)
    assert(code == 3, "an unconfined process sees everything: " .. tostring(code))
    return
  end
  assert(code == 0, "the confined process exited " .. tostring(code))
  assert(assert(Fs.read(own .. "/out")) == "in")
  assert(notes:find("u " .. given .. "\n", 1, true), notes)
  assert(notes:find("u /dev/null\n", 1, true), notes)
  assert(notes:find("e \0environ\n", 1, true), notes)
  assert(not notes:find(own, 1, true), notes)
  assert(not notes:find("p ", 1, true), notes)
  assert(not notes:find("x ", 1, true), notes)
end

--- What a confined process may change outside its test's own directory
--- is no input a key holds, nor is a directory it is handed open.
local function test_a_confined_write_or_descriptor_outside_the_test_is_unkeyable(tmp: string)
  local probe = probe_in(tmp)
  local own, elsewhere = tmp .. "/own", tmp .. "/elsewhere"
  for _, dir in ipairs({ own, elsewhere }) do assert(Fs.mkdirs(dir)) end
  local directory = assert(sys.open(elsewhere, sys.O_RDONLY))
  local run = observations.call(function()
    confine.confine({ reads = { probe }, writes = { elsewhere } })
    assert(Child.run({ probe, "write " .. elsewhere .. "/f x" }))
    assert(Child.run({ probe, "exit 0" }, { fds = { [3] = directory } }))
    confine.confine(nil)
  end, nil, { tree = tmp .. "/tree", own = { own } })
  sys.close(directory)
  assert(run.passed, run.message)
  local notes, unconfined = confined_notes(run)
  assert(assert(Fs.read(elsewhere .. "/f")) == "x\n")
  if unconfined then return end
  assert(notes:find("x " .. elsewhere .. "\n", 1, true), notes)
  assert(notes:find("x fd ", 1, true), notes)
end

--- A confined process has a /tmp of its own to write in; a TMPDIR its
--- test chose is kept, and one it inherits but may not change is the
--- test's own directory instead.
-- TODO: run the inherited-TMPDIR case wherever the host sets none, and
-- one with no environment given, once cosmic.sys can set a variable of
-- this process: today it runs only where the host's TMPDIR is set.
local function test_a_confined_process_has_somewhere_to_write(tmp: string)
  local probe = probe_in(tmp)
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own))
  local chosen = own .. "/chosen"
  local inherited = Env.get("TMPDIR")
  local said: {string} = {}
  local run = observations.call(function()
    confine.confine({ reads = { probe } })
    for _, environment in ipairs({ {} as {string:string}, { TMPDIR = chosen },
        inherited ~= nil and { TMPDIR = inherited } or nil }) do
      local r = assert(Child.run({ probe, "write /tmp/f x && cat /tmp/f; env-of TMPDIR" },
        { env = environment, stdout = "capture" }))
      said[#said + 1] = assert(r.stdout)
    end
    confine.confine(nil)
  end, nil, { tree = tmp .. "/tree", own = { own } })
  assert(run.passed, run.message)
  local _, unconfined = confined_notes(run)
  if unconfined then return end
  assert(said[1] == "x\nTMPDIR unset\n", said[1])
  assert(said[2] == "x\nTMPDIR=" .. chosen .. "\n", said[2])
  if inherited ~= nil and not Fs.within(inherited, own) then
    assert(said[3] == "x\nTMPDIR=" .. own .. "\n", said[3])
  end
end

--- A confined process is given the portable cache its environment
--- names by where that leads, which its root holds, not through a link
--- its root does not: a launcher there would find no cache and end, and
--- could not make one. One not made yet is named by where its parent
--- leads, and one named without a link is kept as named. What it leads
--- to is no read a key must place: the run stays keyable.
local function test_a_confined_process_has_its_portable_cache_by_where_it_leads(tmp: string)
  local probe = probe_in(tmp)
  local own = tmp .. "/own"
  local real = own .. "/real/cache"
  assert(Fs.mkdirs(real))
  assert(Fs.write(real .. "/core", "core"))
  assert(Fs.symlink(own .. "/real", tmp .. "/linked"))
  local resolved = assert(sys.realpath(real))
  local said: {string} = {}
  local run = observations.call(function()
    confine.confine({ reads = { real .. "/core", probe } })
    for _, cache in ipairs({ tmp .. "/linked/cache", resolved, tmp .. "/linked/fresh/cache" }) do
      local r = assert(Child.run({ probe,
        "mkdirs $COSMIC_PORTABLE_CACHE && ls $COSMIC_PORTABLE_CACHE; " ..
        "print $COSMIC_PORTABLE_CACHE" },
        { env = { COSMIC_PORTABLE_CACHE = cache }, stdout = "capture" }))
      said[#said + 1] = assert(r.stdout)
    end
    confine.confine(nil)
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

--- Calls `fn` with the process table's `spawn` refusing, as a kernel
--- with no user namespaces for this user does, every spawn given a
--- sandbox, and answers how many it refused.
local function refusing_sandboxes(fn: function()): integer
  local process = raw_process_table()
  local spawn = process.spawn
  local refused = 0
  process.spawn = function(path: string, argv: {string}, environment: {string:string} | nil,
                       cwd: string | nil, stdin: integer | nil, stdout: integer | nil,
                       stderr: integer | nil, process_group: boolean,
                       fds?: {integer:integer}, sandbox?: raw_process.Sandbox):
                       integer | nil, string, integer
    if sandbox ~= nil then
      refused = refused + 1
      return nil, "Operation not permitted", sys.EPERM
    end
    return spawn(path, argv, environment, cwd, stdin, stdout, stderr, process_group, fds)
  end
  local ok, trouble: boolean, any = pcall(fn)
  process.spawn = spawn
  if not ok then error(trouble, 0) end
  return refused
end

--- Where the kernel cannot confine a process it starts as it would have,
--- in the same directory, and the run is noted "p"; so too a process
--- given more paths than a sandbox holds. Under COSMIC_SANDBOX=must
--- there is no fallback to see (build/must_confine_test.tl holds that
--- mode to refusing it).
local function test_an_unconfinable_process_starts_unconfined(tmp: string)
  if sys.getenv("COSMIC_SANDBOX") == "must" then return end
  local probe = probe_in(tmp)
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own))
  local many: {string} = {}
  for i = 1, 300 do many[i] = tmp .. "/many" .. tostring(i) end
  local run: observations.Run = nil
  local sandboxed = refusing_sandboxes(function()
    run = observations.call(function()
      confine.confine({ reads = { probe } })
      assert(Child.run({ probe, "cwd where" }))
      many[#many + 1] = probe
      confine.confine({ reads = many })
      assert(Child.run({ probe, "exit 0" }))
      confine.confine(nil)
    end, nil, { tree = tmp .. "/tree", own = { own } })
  end)
  assert(run.passed, run.message)
  assert(sandboxed == 1, "only the first was tried confined: " .. tostring(sandboxed))
  local notes, _ = confined_notes(run)
  assert(notes == "p " .. probe .. "\np " .. probe .. "\n", notes)
  assert(assert(Fs.read(own .. "/where")) == assert(Fs.absolute(own)) .. "\n")
end

--- Under `must_confine`, a program exec could not run at all -- a
--- directory, say, which exec refuses with EACCES, an errno a refused
--- sandbox answers too -- fails as its own: the test hears the spawn's
--- failure as it was, and nothing is refused.
local function test_a_must_confined_program_exec_cannot_run_fails_as_its_own(tmp: string)
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own))
  for _, sandboxes in ipairs({ "refused", "real" }) do
    local trouble: string = nil
    local run: observations.Run = nil
    local function attempt()
      run = observations.call(function()
        confine.must_confine({})
        local ran: any = nil
        ran, trouble = Child.run({ own })
        confine.confine(nil)
        assert(ran == nil, "a directory ran")
      end, nil, { tree = tmp .. "/tree", own = { own } })
    end
    if sandboxes == "refused" then refusing_sandboxes(attempt) else attempt() end
    assert(run.passed, sandboxes .. ": " .. run.message)
    assert(not trouble:find("could not start confined", 1, true), trouble)
  end
end

--- A process started with a sandbox of its own that unveils and takes
--- the network is noted by what it was given, as a confined one is; one
--- held only by a pledge is not held to what it reads, and is a "p".
local function test_an_unveiled_sandbox_of_its_own_is_noted_by_what_it_was_given(tmp: string)
  local probe = probe_in(tmp)
  local own, given = tmp .. "/own", tmp .. "/given"
  for _, dir in ipairs({ own, given }) do assert(Fs.mkdirs(dir)) end
  local process = raw_process_table()
  local reads: {string} = { given, probe }
  if sys.stat("/proc") ~= nil then reads[#reads + 1] = "/proc" end
  local ran = true
  local run = observations.call(function()
    local pid, _, errno = process.spawn(probe, { probe, "exit 0" }, nil, "/", nil, nil,
      nil, false, nil, { unveil = { reads = reads, writes = { own } }, offline = true })
    if pid == nil then
      ran = false
      assert(errno ~= nil)
    else
      assert(process.waitpid(pid, false))
    end
    local pledged = process.spawn(probe, { probe, "exit 0" }, nil, nil, nil, nil, nil,
      false, nil, { pledge = {} })
    if pledged ~= nil then assert(process.waitpid(pledged, false)) end
  end, nil, { tree = tmp .. "/tree", own = { own } })
  assert(run.passed, run.message)
  local notes, _ = confined_notes(run)
  if ran then
    assert(notes:find("u " .. given .. "\n", 1, true), notes)
    assert(not notes:find("x " .. probe, 1, true), notes)
  else
    assert(notes:find("x " .. probe .. "\n", 1, true), notes)
  end
  assert(notes:find("p " .. probe .. "\n", 1, true), "a pledge alone: " .. notes)
  assert(not notes:find(own, 1, true), notes)
end

--- A sandbox is noted as the core reads it: raw, so a field a metatable
--- answers for holds nothing; and a path given that leads into /proc
--- or /sys, however spelled, is the host's state.
local function test_an_unveiled_sandbox_is_read_as_the_core_reads_it(tmp: string)
  local probe = probe_in(tmp)
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own))
  local process = raw_process_table()
  -- The stand-in finds itself through /proc, so it is given that too:
  -- given, it runs to its end.
  local reads: {string} = { "//proc/sys/kernel/random", probe }
  if sys.stat("/proc") ~= nil then reads[#reads + 1] = "/proc" end
  local run = observations.call(function()
    local hidden = setmetatable({} as {string:any}, { __index = function(_: any, key: string): any
      if key == "unveil" then return { reads = reads } end
      return nil
    end }) as raw_process.Sandbox
    hidden.offline = true
    local pid = process.spawn(probe, { probe, "exit 0" }, nil, "/", nil, nil, nil, false,
      nil, hidden)
    if pid ~= nil then assert(assert(process.waitpid(pid, false)).code == 0) end
    local given = process.spawn(probe, { probe, "exit 0" }, nil, "/", nil, nil, nil,
      false, nil, { unveil = { reads = reads }, offline = true })
    if given ~= nil then assert(assert(process.waitpid(given, false)).code == 0) end
  end, nil, { tree = tmp .. "/tree", own = { own } })
  assert(run.passed, run.message)
  local notes, _ = confined_notes(run)
  -- The first holds nothing unveiled, so it is a process like any other.
  assert(notes:find("p " .. probe .. "\n", 1, true), notes)
  assert(notes:find("x //proc/sys/kernel/random\n", 1, true) or
    notes:find("x " .. probe .. "\n", 1, true), notes)
  assert(not notes:find("u //proc", 1, true), notes)
end
