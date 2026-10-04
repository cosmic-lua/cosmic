--- The stand-in for `spawn` (build.confine's `enter` and `call`): what a
--- process a test confines in a root of its own is given, and what
--- starts where the kernel can confine none.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local confine = require("build.confine")
local stand_in = require("build.stand_in")
local this_program = require("build.this_program")
local type raw_process = require("cosmic.internal.process")

-- TODO: declare /proc for Linux alone once a declaration can name a
-- host path per platform (a `host` entry for Linux and one for macOS):
-- macOS has no /proc, so there this declares a path that is not there,
-- which gives and keys nothing but says what the tests need wrongly.
--- What the stand-in is tested holding: /proc, where the stand-in program
--- a test starts finds itself; `nests`, since the processes it confines
--- have roots of their own; and `tool`, since a process confined is
--- given the program (the TODO above build.confine's `forbid_running`).
Test.needs{
  host = { "/proc" },
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

--- Whether a process `probe` confined to itself alone, started under
--- `own`'s stand-in, sees `hidden`, which it was not given: false where
--- the kernel confined it, true where it could not and it ran
--- unconfined.
local function sees(probe: string, own: string, hidden: string): boolean
  local code: integer = nil
  local ran = confine.call(function()
    confine.confine({ reads = { probe } })
    local r = assert(Child.run({ probe, "exists " .. hidden .. " 3" }))
    confine.confine(nil)
    code = r.code
  end, nil, { own })
  assert(ran.ok, tostring(ran.produced))
  return code == 3
end

--- `call` answers what its call returned, the very table, and puts back
--- the stand-in it made, whether the call returned or raised.
local function test_a_run_answers_what_its_call_made_and_puts_the_spawn_back(tmp: string)
  local process = raw_process_table()
  local before = process.spawn
  local produced = { answer = 42 }
  local ran = confine.call(function(argument: any): any
    assert(argument == tmp)
    assert(process.spawn ~= before, "no stand-in")
    return produced
  end, tmp, { tmp })
  assert(ran.ok and ran.produced == produced)
  assert(process.spawn == before)
  local failed = confine.call(function() error("expected") end, nil, { tmp })
  assert(not failed.ok and tostring(failed.produced):find("expected", 1, true) ~= nil)
  assert(process.spawn == before)
end

--- A process a test declared what it needs for has that and what every
--- process has -- /dev/null and /proc, and the system's own where its
--- worker has them -- and its test's own directory besides, where it
--- starts; a path it was not given is not there at all.
local function test_a_confined_process_has_what_it_was_given(tmp: string)
  local probe = probe_in(tmp)
  local given, own, hidden = tmp .. "/given", tmp .. "/own", tmp .. "/hidden"
  for _, dir in ipairs({ given, own, hidden }) do assert(Fs.mkdirs(dir)) end
  assert(Fs.write(given .. "/f", "in"))
  assert(Fs.write(hidden .. "/f", "secret"))
  local code: integer = nil
  local ran = confine.call(function()
    confine.confine({ reads = { given, probe } })
    local r = assert(Child.run({ probe,
      "exists " .. hidden .. "/f 3; copy " .. given .. "/f out" }))
    confine.confine(nil)
    code = r.code
  end, nil, { own })
  assert(ran.ok, tostring(ran.produced))
  -- Unconfined, it sees what it was not given.
  if code == 3 then return end
  assert(code == 0, "the confined process exited " .. tostring(code))
  assert(assert(Fs.read(own .. "/out")) == "in")
end

--- A process a library's work starts (`declaring`), under a stand-in
--- that says this process runs in a sandbox, inherits that sandbox and
--- is confined no further, even in a stand-in of the test's own, which
--- says nothing of one: it sees what this process sees.
local function test_a_process_a_library_declares_in_a_sandbox_is_held_by_it(tmp: string)
  local probe = probe_in(tmp)
  local own, hidden = tmp .. "/own", tmp .. "/hidden"
  for _, dir in ipairs({ own, hidden }) do assert(Fs.mkdirs(dir)) end
  local code: integer = nil
  local ran = confine.call(function()
    local inner = confine.call(function()
      confine.declaring({ reads = { probe }, writes = {} }, function()
        code = assert(Child.run({ probe, "exists " .. hidden .. " 3" })).code
      end)
    end, nil, { own })
    assert(inner.ok, tostring(inner.produced))
  end, nil, { own }, true)
  assert(ran.ok, tostring(ran.produced))
  assert(code == 3, "a library's process was confined in a sandbox: " .. tostring(code))
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
  assert(Fs.mkdirs(own .. "/hidden"))
  if sees(probe, own, own .. "/hidden") then return end -- the kernel confines none
  local chosen = own .. "/chosen"
  local inherited = Env.get("TMPDIR")
  local said: {string} = {}
  local ran = confine.call(function()
    confine.confine({ reads = { probe } })
    for _, environment in ipairs({ {} as {string:string}, { TMPDIR = chosen },
        inherited ~= nil and { TMPDIR = inherited } or nil }) do
      local r = assert(Child.run({ probe, "write /tmp/f x && cat /tmp/f; env-of TMPDIR" },
        { env = environment, stdout = "capture" }))
      said[#said + 1] = assert(r.stdout)
    end
    confine.confine(nil)
  end, nil, { own })
  assert(ran.ok, tostring(ran.produced))
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
--- leads, and one named without a link is kept as named.
local function test_a_confined_process_has_its_portable_cache_by_where_it_leads(tmp: string)
  local probe = probe_in(tmp)
  local own = tmp .. "/own"
  local real = own .. "/real/cache"
  assert(Fs.mkdirs(real))
  assert(Fs.mkdirs(own .. "/hidden"))
  if sees(probe, own, own .. "/hidden") then return end -- the kernel confines none
  assert(Fs.write(real .. "/core", "core"))
  assert(Fs.symlink(own .. "/real", tmp .. "/linked"))
  local resolved = assert(sys.realpath(real))
  local said: {string} = {}
  local ran = confine.call(function()
    confine.confine({ reads = { real .. "/core", probe } })
    for _, cache in ipairs({ tmp .. "/linked/cache", resolved, tmp .. "/linked/fresh/cache" }) do
      local r = assert(Child.run({ probe,
        "mkdirs $COSMIC_PORTABLE_CACHE && ls $COSMIC_PORTABLE_CACHE; " ..
          "print $COSMIC_PORTABLE_CACHE" },
        { env = { COSMIC_PORTABLE_CACHE = cache }, stdout = "capture" }))
      said[#said + 1] = assert(r.stdout)
    end
    confine.confine(nil)
  end, nil, { own })
  assert(ran.ok, tostring(ran.produced))
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
                           fds?: {integer:integer}, sandbox?: raw_process.Sandbox,
                           credentials?: raw_process.Credentials):
      integer | nil, string, integer
    if sandbox ~= nil then
      refused = refused + 1
      return nil, "Operation not permitted", sys.EPERM
    end
    return spawn(path, argv, environment, cwd, stdin, stdout, stderr, process_group, fds, sandbox, credentials)
  end
  local ok, trouble: boolean, any = pcall(fn)
  process.spawn = spawn
  if not ok then error(trouble, 0) end
  return refused
end

--- Where the kernel cannot confine a process it starts as it would have,
--- in the same directory; so too a process given more paths than a
--- sandbox holds, which is not tried confined at all. Under
--- COSMIC_SANDBOX=must there is no fallback to see
--- (build/must_confine_test.tl holds that mode to refusing it).
local function test_an_unconfinable_process_starts_unconfined(tmp: string)
  if sys.getenv("COSMIC_SANDBOX") == "must" then return end
  local probe = probe_in(tmp)
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own))
  local many: {string} = {}
  for i = 1, 300 do many[i] = tmp .. "/many" .. tostring(i) end
  local ran: confine.Ran = nil
  local sandboxed = refusing_sandboxes(function()
    ran = confine.call(function()
      confine.confine({ reads = { probe } })
      assert(Child.run({ probe, "cwd where" }))
      many[#many + 1] = probe
      confine.confine({ reads = many })
      assert(Child.run({ probe, "exit 0" }))
      confine.confine(nil)
    end, nil, { own })
  end)
  assert(ran.ok, tostring(ran.produced))
  assert(sandboxed == 1, "only the first was tried confined: " .. tostring(sandboxed))
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
    local ran: confine.Ran = nil
    local function attempt()
      ran = confine.call(function()
        confine.must_confine({})
        local started: any = nil
        started, trouble = Child.run({ own })
        confine.confine(nil)
        assert(started == nil, "a directory ran")
      end, nil, { own })
    end
    if sandboxes == "refused" then refusing_sandboxes(attempt) else attempt() end
    assert(ran.ok, sandboxes .. ": " .. tostring(ran.produced))
    assert(not trouble:find("could not start confined", 1, true), trouble)
  end
end

--- `forbid_running` given `within`, the paths a process the policy holds may
--- run, since it cannot list /: the program is refused by its own name, by
--- a link to it and by /proc/self/exe, and a sibling program, in a directory
--- it is told, still runs. A process of its own takes the hold, which
--- lasts for good.
local function test_forbid_running_within_refuses_the_program_by_every_name(tmp: string)
  local sibling = assert(stand_in.build(tmp .. "/sibling/stand-in"))
  local program = confine.itself()[1]
  assert(Fs.mkdirs(tmp .. "/links"))
  assert(Fs.symlink(program, tmp .. "/links/program"))
  local within = { Fs.dirname(sibling), tmp .. "/links", Fs.dirname(program) }
  local chunk = string.format([=[
local Child = require("cosmic.child")
local confine = require("build.confine")
local ok, why = confine.forbid_running(confine.itself(), %s)
assert(ok, why)
local function ran(argv)
  local result, trouble = Child.run(argv)
  if result == nil then return trouble end
  return "ran " .. tostring(result.code)
end
local out = {
  "program " .. ran({ %q }),
  "link " .. ran({ %q }),
  "exe " .. ran({ "/proc/self/exe" }),
  "sibling " .. ran({ %q, "exists / 3" }),
}
require("cosmic.fs").put(1, table.concat(out, "\n"))
]=], "{ " .. string.format("%q, %q, %q", within[1], within[2], within[3]) .. " }",
    program, tmp .. "/links/program", sibling)
  local started = this_program.program({ "-e", chunk }, { stdout = "capture", stderr = "stdout" })
  local result = assert(Child.run(started.argv, started.options))
  local said = assert(result.stdout)
  assert(said:find("program child: start: Permission denied", 1, true), said)
  assert(said:find("link child: start: Permission denied", 1, true), said)
  assert(said:find("exe child: start: Permission denied", 1, true), said)
  assert(said:find("sibling ran 3", 1, true), said)
end
