--- End to end: a sandboxed run keys each verdict by its test's
--- declared inputs (build/declared_key.tl). A verdict stands while
--- nothing declared changes -- whatever else of the tree does -- and in
--- another checkout of the same content, through the shared cache; a
--- test runs again when what it declares changes, always when it
--- declares a host of the network beyond the loopback, and every test
--- runs under `--all`. Where this host cannot sandbox a worker -- one
--- nested in this test's own confinement, three deep, which the kernel
--- refuses root (core/syscalls.c's `map_ids`) -- the run says so, and
--- there is nothing more to check, unless the run is held to
--- sandboxing (`unsandboxed`): then it fails. A test that runs this
--- program undeclared is refused it, sandboxed, and one that declares `tool`
--- runs again when the tool does -- when what the tool runs as does,
--- not when only the rows every edit of the tree moves do.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local artifact = require("build.artifact")
local confine = require("build.confine")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- What a sandboxed run of `cosmic test` needs of the host, and the
--- program it runs.
Test.needs{
  host = { "/dev/urandom", "/proc" },
  env = { "COSMIC_SANDBOX", "COSMIC_CI_REQUIRE_SANDBOX", "COSMIC_TEST_SANDBOX" },
  tool = true,
}

-- What these tests start is this very program.
confine.confine({ reads = confine.itself() })

--- A checkout of the suite at `root`: a test that reads a declared
--- directory, one that reads a declared variable, one that loads a
--- module of the tree, one that declares a host of the network beyond
--- the loopback, and a file nothing declares.
local function checkout(root: string)
  assert(Fs.mkdirs(root .. "/suite/data"))
  assert(Fs.write(root .. "/suite/data/f", "one\n"))
  assert(Fs.write(root .. "/suite/unrelated.txt", "u\n"))
  assert(Fs.write(root .. "/suite/lib.tl", "return { value = 1 }\n"))
  assert(Fs.write(root .. "/suite/data_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/data/" } }

local function test_data()
  assert(Fs.read("suite/data/f") ~= nil)
end
]]))
  assert(Fs.write(root .. "/suite/flavour_test.tl", [[
local Env = require("cosmic.env")
local Test = require("cosmic.test")

Test.needs { env = { "FLAVOUR" } }

local function test_flavour()
  assert(Env.get("FLAVOUR") ~= "sour")
end
]]))
  assert(Fs.write(root .. "/suite/plain_test.tl", [[
local lib = require("suite.lib")

local function test_plain()
  assert(lib.value ~= nil)
end
]]))
  assert(Fs.write(root .. "/suite/net_test.tl", [[
local Test = require("cosmic.test")

Test.needs { network = { "example.com" } }

local function test_net()
  assert(true)
end
]]))
end

--- Whether a run that said `text` sandboxed no worker, where that is
--- allowed: false where it did sandbox them, and a failure where this
--- run is held to sandboxing -- COSMIC_TEST_SANDBOX=1, as CI's suites
--- set it, COSMIC_SANDBOX=must or COSMIC_CI_REQUIRE_SANDBOX=1 -- so a run
--- held to it proves the runs it starts sandbox theirs, nested in its
--- own as they are (CI's unprivileged runner nests them, as
--- build/shared_verdicts_test.tl's `shares` holds it to). Elsewhere, a
--- host that refuses a worker's workers a sandbox of their own -- one
--- running the tests as root, this test's run confined in a sandbox
--- already -- checks nothing here.
local function unsandboxed(text: string): boolean
  if text:find("; sandboxed)", 1, true) then return false end
  assert(not confine.held_to_sandbox(),
    "the run is held to sandboxing, but the run it started was not:\n" .. text)
  return true
end

--- The environment a sandboxed run of the suite is started with, its
--- shared cache at `cache`.
local function environment(cache: string): {string:string}
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = cache
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_TEST_NO_SHARED = nil
  env.COSMIC_SANDBOX = nil
  -- Sandboxed where it can be, whatever this run's own switch says:
  -- this test's worker, unsandboxed, may start runs that are.
  env.COSMIC_TEST_SANDBOX = nil
  env.FLAVOUR = "sweet"
  return env
end

--- Runs `cosmic test` on `root` with `words` after it, answering what it
--- printed, which must say it passed -- unless `unchecked`, for a run that
--- may have sandboxed nothing. Either way it must have started: a run
--- that did not printed nothing, which reads as one that sandboxed
--- nothing (`unsandboxed`).
local function run(root: string, output: string, env: {string:string}, words?: {string},
                   unchecked?: boolean): string
  local fd = assert(Fs.open_write(output))
  local args: {string} = { "test" }
  for _, word in ipairs(words or {}) do args[#args + 1] = word end
  local started = this_program.program(args, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ms = 60000,
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  -- A run that never started sandboxed nothing, and says nothing of it.
  assert(result ~= nil, tostring(trouble) .. text)
  assert(unchecked or result.ok, tostring(trouble) .. text)
  return text
end

--- A checkout of the suite in `tmp`, run once, sandboxed: the
--- environment its runs take, and a check of a run after the last one
--- -- what it says, with `words` after `test` -- and the root it runs
--- in; nil where no worker could be sandboxed. Each case below seeds
--- its own, so none starts more nested runs than a test's bound (10 s
--- in CI) holds under load.
local type Said = function(string, ?{string}): string

local function seeded(tmp: string): {string:string}, Said, string
  local root = tmp .. "/root"
  checkout(root)
  local env = environment(tmp .. "/cache/verdicts.db")
  local step = 0
  local function said(wanted: string, words?: {string}): string
    step = step + 1
    local text = run(root, tmp .. "/" .. step .. ".out", env, words)
    assert(text:find(wanted, 1, true), step .. ": " .. text)
    return text
  end
  local first = run(root, tmp .. "/first.out", env)
  if unsandboxed(first) then return env, said, nil end
  assert(first:find("4 ran, 0 stood", 1, true) and first:find("; sandboxed", 1, true), first)
  return env, said, root
end

--- Nothing changed, or only a file no test declares: all but the test
--- that reaches the network stands, and none is assumed.
local function test_a_sandboxed_verdict_stands_until_what_it_declares_changes(tmp: string)
  local _, said, root = seeded(tmp)
  if root == nil then return end
  local again = said("1 ran, 3 stood")
  assert(not again:find("assumed", 1, true), again)
  -- A file no test declares.
  assert(Fs.write(root .. "/suite/unrelated.txt", "changed\n"))
  said("1 ran, 3 stood")
end

--- A file beneath a declared directory, or a module of a test's
--- closure, runs the test that declares it.
local function test_a_declared_file_or_module_that_changes_runs_its_test(tmp: string)
  local _, said, root = seeded(tmp)
  if root == nil then return end
  assert(Fs.write(root .. "/suite/data/f", "two\n"))
  said("2 ran, 2 stood")
  assert(Fs.write(root .. "/suite/lib.tl", "return { value = 2 }\n"))
  said("2 ran, 2 stood")
end

--- A declared variable's value, or the declaration itself, that changes
--- runs the test that declares it.
local function test_a_declared_variable_or_declaration_that_changes_runs_its_test(tmp: string)
  local env, said, root = seeded(tmp)
  if root == nil then return end
  env.FLAVOUR = "salty"
  said("2 ran, 2 stood")
  local source = assert(Fs.read(root .. "/suite/data_test.tl"))
  assert(Fs.write(root .. "/suite/data_test.tl",
    (source:gsub('reads = { "suite/data/" }', 'reads = { "suite/data/", "suite/lib.tl" }'))))
  said("2 ran, 2 stood")
end

--- Forced, by `--all` or COSMIC_TEST_ALL, every test runs.
local function test_a_forced_run_runs_every_sandboxed_test(tmp: string)
  local env, said, root = seeded(tmp)
  if root == nil then return end
  said("4 ran, 0 stood", { "--all" })
  env.COSMIC_TEST_ALL = "1"
  said("4 ran, 0 stood")
end

--- A test that declares only loopback hosts runs offline, in a network
--- namespace of its own, where a closed port is refused as on the
--- host's; its verdict stands as any other's, and one that declares
--- another host beside them runs every time, online -- in the namespace
--- the run itself is in, which every online worker shares. So the two
--- are told apart by their namespaces, which each names in a failure of
--- its own in a checkout that probes them: a worker keyed but left
--- online would share its sibling's.
local function test_a_test_that_declares_only_loopback_hosts_stands(tmp: string)
  local source = [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Test = require("cosmic.test")

Test.needs { network = { HOSTS } }

local function test_refused()
  local response, trouble = Http.open("http://127.0.0.1:1/", { connect_timeout_ms = 2000 })
  assert(response == nil and trouble ~= "")
  if PROBE then error("NAME in " .. tostring((Fs.readlink("/proc/self/ns/net"))) .. " |") end
end
]]
  local function suite(root: string, probe: boolean)
    assert(Fs.mkdirs(root .. "/suite"))
    for name, hosts in pairs({ loopback = '"127.0.0.1", "127.0.0.2", "::1", "localhost"',
                               mixed = '"127.0.0.1", "example.com"' }) do
      local text = source:gsub("HOSTS", hosts):gsub("PROBE", tostring(probe)):gsub("NAME", name)
      assert(Fs.write(root .. "/suite/" .. name .. "_test.tl", text))
    end
  end
  local env = environment(tmp .. "/cache/verdicts.db")
  suite(tmp .. "/root", false)
  local first = run(tmp .. "/root", tmp .. "/first.out", env)
  if unsandboxed(first) then return end
  assert(first:find("2 ran, 0 stood", 1, true), first)
  local again = run(tmp .. "/root", tmp .. "/again.out", env)
  assert(again:find("1 ran, 1 stood, 1 run every time", 1, true), again)
  suite(tmp .. "/probe", true)
  local probed = run(tmp .. "/probe", tmp .. "/probe.out", env, nil, true)
  local offline = probed:match("loopback in (%S+) |")
  local online = probed:match("mixed in (%S+) |")
  assert(offline ~= nil and online ~= nil and offline:find("^net:") and offline ~= online,
    probed)
end

--- A checkout of the same content stands on the verdicts another
--- reached, by their keys alone, and one whose declared input differs
--- runs that test.
local function test_a_sandboxed_verdict_stands_in_another_checkout(tmp: string)
  local env = environment(tmp .. "/cache/verdicts.db")
  checkout(tmp .. "/first")
  local first = run(tmp .. "/first", tmp .. "/first.out", env)
  if unsandboxed(first) then return end
  assert(first:find("4 ran, 0 stood", 1, true), first)
  checkout(tmp .. "/second")
  local second = run(tmp .. "/second", tmp .. "/second.out", env)
  assert(second:find("1 ran, 3 stood, 1 run every time", 1, true) and
    second:find("3 of them on another checkout's verdict", 1, true), second)
  checkout(tmp .. "/third")
  assert(Fs.write(tmp .. "/third/suite/data/f", "three\n"))
  local third = run(tmp .. "/third", tmp .. "/third.out", env)
  assert(third:find("2 ran, 2 stood, 1 run every time", 1, true) and
    third:find("2 of them on another checkout's verdict", 1, true), third)
end

--- Told to stand on no other checkout's verdicts, a checkout runs
--- everything.
local function test_a_sandboxed_checkout_told_to_share_nothing_runs_everything(tmp: string)
  local env = environment(tmp .. "/cache/verdicts.db")
  checkout(tmp .. "/first")
  local first = run(tmp .. "/first", tmp .. "/first.out", env)
  if unsandboxed(first) then return end
  assert(first:find("4 ran, 0 stood", 1, true), first)
  checkout(tmp .. "/unshared")
  local unshared = run(tmp .. "/unshared", tmp .. "/unshared.out", env, { "--no-shared" })
  assert(unshared:find("4 ran, 0 stood", 1, true), unshared)
end

--- A checkout whose tests run this program: one that declares `tool`,
--- and one that does not, which must find it refused.
local function tool_checkout(root: string)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/o/bin"))
  assert(Fs.write(root .. "/o/bin/stand-in", "one\n"))
  -- Each starts this program past its launcher by hand, as
  -- `this_program.program` would: another project cannot reach build/.
  -- TODO: start it through `this_program.program` once that moves to
  -- `cosmic.test` (the TODO above it in build/this_program.tl).
  local started = [[
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")

local function started(args: {string}): Child.Result | nil, string
  local relaunch = Proc.relaunch()
  local argv: {string} = {}
  for _, word in ipairs(relaunch ~= nil and relaunch.argv or { assert(Proc.executable()) }) do
    argv[#argv + 1] = word
  end
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local env = Env.all()
  for name, value in pairs(relaunch ~= nil and relaunch.env or {}) do env[name] = value end
  return Child.run(argv, { env = env, fds = relaunch ~= nil and relaunch.fds or {} })
end
]]
  assert(Fs.write(root .. "/suite/tool_test.tl", started .. [[
local Test = require("cosmic.test")

Test.needs { tool = true }

local function test_runs_the_tool()
  local result = assert(started({ "-e", "" }))
  assert(result.ok)
end
]]))
  assert(Fs.write(root .. "/suite/undeclared_test.tl", started .. [[

local function test_is_refused_the_tool()
  -- The program is not given it at all, and its core is refused it,
  -- the artifact's descriptor with it.
  local result, trouble = Child.run({ assert(Proc.executable()), "-e", "" })
  assert(result == nil, "the program ran undeclared")
  assert(trouble:find("o such file", 1, true), trouble)
  local ok, why = pcall(started, { "-e", "" })
  assert(not ok, "the program's core ran undeclared")
  assert(tostring(why):find("retained artifact descriptor", 1, true), tostring(why))
  local relaunch = assert(Proc.relaunch())
  local core, core_trouble = Child.run({ relaunch.argv[1], "-e", "" })
  assert(core == nil, "the program's core ran undeclared")
  assert(core_trouble:find("ermission denied", 1, true), core_trouble)
  local exe, exe_trouble = Child.run({ "/proc/self/exe", "-e", "" })
  assert(exe == nil, "the program ran through /proc/self/exe")
  local _ = exe_trouble
end
]]))
end

--- Sandboxed, a test that runs this program undeclared is refused it,
--- and one that declares `tool` runs again when the tool changes -- the
--- tool's own modules, which it runs, are none of its closure's.
local function test_a_sandboxed_test_runs_the_tool_only_declared(tmp: string)
  local root = tmp .. "/root"
  tool_checkout(root)
  local env = environment(tmp .. "/cache/verdicts.db")
  local first = run(root, tmp .. "/first.out", env, nil, true)
  if unsandboxed(first) then return end
  assert(first:find("test: PASS", 1, true) and first:find("2 ran, 0 stood", 1, true), first)
  local again = run(root, tmp .. "/again.out", env)
  assert(again:find("0 ran, 2 stood", 1, true), again)
  -- The tool rebuilt: what declares it runs again.
  assert(Fs.write(root .. "/o/bin/stand-in", "two\n"))
  local rebuilt = run(root, tmp .. "/rebuilt.out", env)
  assert(rebuilt:find("1 ran, 1 stood", 1, true), rebuilt)
end

--- This program, rebuilt at `path` with `statements` run on the
--- database it carries (`artifact.split`), as a rebuild of the tool
--- moves it: a host program of this program's core
--- (`artifact.host_program`), which the kernel runs itself, with no
--- launcher and no shell of the system's to find.
local function rebuilt(tmp: string, path: string, statements: string)
  local executable = assert(Proc.executable())
  local parts = assert(artifact.split((assert(Fs.read(executable)))))
  local db_path = tmp .. "/carried.db"
  local _, _ = Fs.remove(db_path)
  assert(Fs.write(db_path, parts.database))
  local db = assert(Sqlite.open(db_path, true))
  assert(db:exec(statements))
  assert(db:close())
  local program = assert(artifact.host_program(assert(artifact.trusted_core()),
    (assert(Fs.read(db_path)))))
  local _, _ = Fs.remove(path)
  assert(Fs.write(path, program))
  assert(sys.chmod(path, 493)) -- 0o755
end

--- A project whose one test declares `tool` and whose other does not,
--- in `tmp`, run once by a copy of this program in its o/bin, sandboxed:
--- how to rebuild that copy with statements run on the database it
--- carries, and a check of a run of it after the last one; nil for both
--- where no worker could be sandboxed.
-- The tree's own tool rebuilds for such an edit only in cosmic's own
-- tree, too big to copy here: the program run instead is this one's
-- core, as a host program, carrying this one's rows rewritten as each
-- rebuild would leave them.
local function tool_project(tmp: string): function(string), function(string): string
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/o/bin"))
  -- Its worker does not start the tool, which a sandbox nested in this
  -- test's confinement could not find at its name under this test's
  -- /tmp: what it declares is all its key turns on.
  assert(Fs.write(root .. "/suite/tool_test.tl",
    "local Test = require(\"cosmic.test\")\n\nTest.needs { tool = true }\n\n" ..
    "local function test_tool()\nend\n"))
  assert(Fs.write(root .. "/suite/plain_test.tl", "local function test_plain()\nend\n"))
  local tool = root .. "/o/bin/cosmic"
  local function rebuild(statements: string)
    rebuilt(tmp, tool, statements)
  end
  rebuild("UPDATE meta SET value = 'one' WHERE key IN ('boot_hash', 'projected')")
  local env = environment(tmp .. "/cache/verdicts.db")
  env.COSMIC_VERDICT_CACHE = "0"
  local step = 0
  local function ran(wanted: string, unchecked?: boolean): string
    step = step + 1
    local fd = assert(Fs.open_write(tmp .. "/" .. step .. ".out"))
    local result, trouble = Child.run({ tool, "test" }, {
      cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ms = 60000,
    })
    assert(Fs.close(fd))
    local text = assert(Fs.read(tmp .. "/" .. step .. ".out"))
    assert(result ~= nil, tostring(trouble) .. text)
    assert(unchecked or result.ok, tostring(trouble) .. text)
    if wanted ~= "" then assert(text:find(wanted, 1, true), step .. ": " .. text) end
    return text
  end
  local first = ran("", true)
  if unsandboxed(first) then return nil, nil end
  assert(first:find("test: PASS", 1, true) and first:find("2 ran, 0 stood", 1, true), first)
  return rebuild, function(wanted: string): string return ran(wanted) end
end

--- A test that declares `tool` stands across a rebuild of the tool that
--- moved only `boot_hash` and `projected` -- what an edit to nothing a
--- binary carries moves, as a boot after a comment in a test does; so
--- does one that does not declare it.
local function test_a_tool_test_stands_across_a_rebuild_that_moved_nothing_it_carries(tmp: string)
  local rebuild, ran = tool_project(tmp)
  if rebuild == nil then return end
  ran("0 ran, 2 stood")
  -- Rebuilt for an edit no binary carries: every byte of the program
  -- after its image moved, and nothing it runs.
  rebuild("UPDATE meta SET value = 'two' WHERE key IN ('boot_hash', 'projected')")
  ran("0 ran, 2 stood")
end

--- A test that declares `tool` runs again when a module the tool
--- carries moves; one that does not declare it stands.
local function test_a_tool_test_runs_again_when_a_module_the_tool_carries_moves(tmp: string)
  local rebuild, ran = tool_project(tmp)
  if rebuild == nil then return end
  rebuild("UPDATE modules SET source = deflate(CAST(inflate(source) AS TEXT) || " ..
    "char(10) || '-- edited' || char(10)) WHERE path = 'cosmic.json'")
  ran("1 ran, 1 stood")
end

--- Writes `data` over the file at `path` in place, as a sandbox that
--- was given the file itself sees it change.
local function overwrite(path: string, data: string)
  local fd = assert(sys.open(path, sys.O_WRONLY | sys.O_TRUNC))
  assert(sys.write(fd, data) == #data)
  assert(sys.close(fd))
end

--- A verdict reached while a declared input moved under the test is
--- kept under neither key: a pass is kept only when its inputs still
--- digest to the key it started from, and a failure takes a pass under
--- that key out, so the test runs again when they are back.
---
--- The test it runs holds its input still until told to stop -- a file
--- in its own directory -- or until it moves, so a run that moves
--- nothing costs no fixed wait: each run is started, and once the test
--- says it started, is either stopped or has its input moved under it.
local function test_a_verdict_whose_inputs_moved_as_it_ran_is_not_kept(tmp: string)
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/moving.txt", "one\n"))
  -- It says it started, and fails if what it reads moves before it is
  -- stopped (or 20 s pass, a bound no run here reaches).
  assert(Fs.write(root .. "/suite/moving_test.tl", [[
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/moving.txt" } }

local function test_moving(tmp: string)
  local was = Fs.read("suite/moving.txt")
  assert(Fs.write(tmp .. "/started", "yes"))
  local deadline = Time.monotonic_ns() + 20000000000
  while not Fs.exists(tmp .. "/stop") and Time.monotonic_ns() < deadline do
    assert(Fs.read("suite/moving.txt") == was, "it moved")
    assert(Time.sleep_ns(20000000))
  end
end
]]))
  local env = environment(tmp .. "/cache/verdicts.db")
  env.COSMIC_VERDICT_CACHE = "0"
  assert(Fs.mkdirs(tmp .. "/t"))
  env.TMPDIR = assert(Fs.absolute(tmp .. "/t"))
  local step = 0
  -- A run of `words` after `test`: once its test says it started --
  -- its directory is one of TMPDIR's, sandboxed or not -- `then_do`
  -- moves its input or stops it. What the run said, and whether it
  -- passed.
  local function run_then(words: {string}, then_do: function(string)): string, boolean
    step = step + 1
    local out = tmp .. "/" .. step .. ".out"
    local fd = assert(Fs.open_write(out))
    local args: {string} = { "test" }
    for _, word in ipairs(words) do args[#args + 1] = word end
    local started = this_program.program(args, {
      cwd = root, env = env, stdout = fd, stderr = fd, process_group = true,
    })
    local handle = assert(Child.start(started.argv, started.options))
    local deadline = Time.monotonic_ns() + 30000000000
    local found = ""
    local ended = false
    while found == "" and not ended and Time.monotonic_ns() < deadline do
      local now, _ = handle:try_wait()
      ended = now ~= nil and now.finished
      for _, entry in ipairs(Fs.list(tmp .. "/t") or {}) do
        for _, sub in ipairs({ "/real", "/tmp", "" }) do
          local dir = tmp .. "/t/" .. entry .. sub
          if Fs.exists(dir .. "/started") and not Fs.exists(dir .. "/stop") then found = dir end
        end
      end
      if found == "" then assert(Time.sleep_ns(20000000)) end
    end
    assert(found ~= "" or ended, "the test never started")
    if found ~= "" then then_do(found) end
    local result = assert(handle:wait(60000))
    assert(Fs.close(fd))
    -- Its directory said it started: marked so the next run's is found.
    if found ~= "" then local _ = Fs.write(found .. "/stop", "") end
    return assert(Fs.read(out)), result.ok
  end
  local function stop(dir: string) assert(Fs.write(dir .. "/stop", "")) end
  local first, first_ok = run_then({}, stop)
  if unsandboxed(first) then return end
  assert(first_ok and first:find("1 ran, 0 stood", 1, true), first)
  -- Forced, and moved as it runs: it fails.
  local forced, forced_ok = run_then({ "--all" }, function(_: string)
    overwrite(root .. "/suite/moving.txt", "two\n")
  end)
  assert(not forced_ok and forced:find("it moved", 1, true), forced)
  -- Back as it was: the pass its first run kept is gone with the
  -- failure, so it runs; then it stands.
  overwrite(root .. "/suite/moving.txt", "one\n")
  local back, back_ok = run_then({}, stop)
  assert(back_ok and back:find("1 ran, 0 stood", 1, true), back)
  local stands = run(root, tmp .. "/stands.out", env)
  assert(stands:find("0 ran, 1 stood", 1, true), stands)
end

--- The harness every worker runs is in every sandboxed key: a change to
--- it -- stood in for by COSMIC_TEST_HARNESS_SALT, as a binary with
--- another harness would bring -- runs a test that shares nothing else
--- with it again.
local function test_a_change_to_the_harness_runs_every_test_again(tmp: string)
  local root = tmp .. "/root"
  checkout(root)
  local env = environment(tmp .. "/cache/verdicts.db")
  local first = run(root, tmp .. "/first.out", env)
  if unsandboxed(first) then return end
  local again = run(root, tmp .. "/again.out", env)
  assert(again:find("1 ran, 3 stood", 1, true), again)
  env.COSMIC_TEST_HARNESS_SALT = "another harness"
  local moved = run(root, tmp .. "/moved.out", env)
  assert(moved:find("4 ran, 0 stood", 1, true), moved)
end

--- A compiler of another identity that makes the same bytecode --
--- stood in for by COSMIC_TEST_COMPILER_SALT, under which the tree is
--- compiled again -- moves no key but that of a test whose closure
--- reads the compiler's identity (build/declared_key.tl's
--- `compiler_readers`, which the fixture's `core.allocation_test`
--- stands in for by its name): the module's key the key holds is the
--- compiler's graph key, the store's address holds what the compiler
--- made, and the compiler itself only where it is read.
local function test_a_compiler_that_makes_the_same_bytecode_runs_only_its_readers(tmp: string)
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.write(root .. "/suite/lib.tl", "return { value = 1 }\n"))
  assert(Fs.write(root .. "/suite/plain_test.tl", [[
local lib = require("suite.lib")

local function test_plain()
  assert(lib.value == 1)
end
]]))
  assert(Fs.write(root .. "/core/allocation_test.tl", [[
local lib = require("suite.lib")

local function test_reads()
  assert(lib.value == 1)
end
]]))
  local env = environment(tmp .. "/cache/verdicts.db")
  local first = run(root, tmp .. "/first.out", env)
  if unsandboxed(first) then return end
  assert(first:find("2 ran, 0 stood", 1, true), first)
  env.COSMIC_TEST_COMPILER_SALT = "another compiler"
  local moved = run(root, tmp .. "/moved.out", env)
  assert(moved:find("1 ran, 1 stood", 1, true), moved)
  local db = assert(Sqlite.open(root .. "/o/build.db", false))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT group_concat(path, ' ') FROM (SELECT path FROM runs " ..
    "WHERE run_at_ns = (SELECT max(run_at_ns) FROM runs) ORDER BY path)"))
  assert(db:close())
  assert(rows[1][1] == "core.allocation_test", "ran under another compiler: " .. rows[1][1])
end

--- A test whose module does not declare `store` is given the store of
--- its import closure at o/cosmic.db (build/closure_store.tl's `write`), in
--- the projection's place: it holds none of the tree's modules outside
--- the closure, which a `require` is refused anyway, and its verdict
--- stands across an edit to one of them -- which rewrites the projection
--- -- and across a module added, which a `require` is refused too; while
--- one to a module of the closure runs it again. A store no module names
--- any longer is taken out.
local function test_a_test_is_given_the_store_of_its_closure_alone(tmp: string)
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/lib.tl", "return { value = 1 }\n"))
  assert(Fs.write(root .. "/suite/other.tl", "return { value = 1 }\n"))
  assert(Fs.write(root .. "/suite/closed_test.tl", [[
local Env = require("cosmic.env")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local lib = require("suite.lib")

Test.needs { env = { "ADDED" } }

local function test_closed()
  assert(lib.value == 1)
  assert(Store.bytecode("suite.lib") ~= nil, "the closure is not in the store")
  local bytes, _ = Store.bytecode("suite.other")
  assert(bytes == nil, "a module outside the closure is in the store")
  local ok, why = pcall(require, ("suite." .. "other"))
  assert(not ok and tostring(why):find("outside the import closure", 1, true), tostring(why))
  if Env.get("ADDED") == "1" then
    local added, added_why = pcall(require, ("suite." .. "added"))
    assert(not added and tostring(added_why):find("outside the import closure", 1, true),
      tostring(added_why))
  end
end
]]))
  local env = environment(tmp .. "/cache/verdicts.db")
  -- Unchecked: where no worker can be sandboxed, the run is
  -- unsandboxed, its worker attaches the whole projection, and the
  -- test fails -- `unsandboxed` then ends this one.
  local first = run(root, tmp .. "/first.out", env, nil, true)
  if unsandboxed(first) then return end
  assert(first:find("test: PASS", 1, true) and first:find("1 ran, 0 stood", 1, true), first)
  local projection = assert(Fs.read(root .. "/o/cosmic.db"))
  local stores = assert(Fs.list(root .. "/o/stores"))
  assert(#stores == 1, table.concat(stores, " "))
  -- Outside the closure: the projection moves, the verdict stands.
  assert(Fs.write(root .. "/suite/other.tl", "return { value = 2 }\n"))
  local outside = run(root, tmp .. "/outside.out", env)
  assert(outside:find("0 ran, 1 stood", 1, true), outside)
  assert(assert(Fs.read(root .. "/o/cosmic.db")) ~= projection, "the projection did not move")
  -- A module added: it stands, on the same store; told to look, it
  -- finds a `require` of the new module refused.
  assert(Fs.write(root .. "/suite/added.tl", "return {}\n"))
  local added = run(root, tmp .. "/added.out", env)
  assert(added:find("0 ran, 1 stood", 1, true), added)
  assert(#assert(Fs.list(root .. "/o/stores")) == 1)
  env.ADDED = "1"
  local looked = run(root, tmp .. "/looked.out", env)
  assert(looked:find("1 ran, 0 stood", 1, true), looked)
  env.ADDED = nil
  -- Inside it: it runs again, given a store of its own, and the one
  -- before is taken out.
  assert(Fs.write(root .. "/suite/lib.tl", "-- edited\nreturn { value = 1 }\n"))
  local inside = run(root, tmp .. "/inside.out", env)
  assert(inside:find("1 ran, 0 stood", 1, true), inside)
  local now = assert(Fs.list(root .. "/o/stores"))
  assert(#now == 1 and now[1] ~= stores[1], table.concat(now, " "))
end
