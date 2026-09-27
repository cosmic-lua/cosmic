--- End to end: a sandboxed run keys each verdict by its test's
--- declared inputs (build/declared_key.tl). A verdict stands while
--- nothing declared changes -- whatever else of the tree does -- and in
--- another checkout of the same content, through the shared cache; a
--- test runs again when what it declares changes, always when it
--- declares the network, and every test runs under `--all`. Where this
--- host cannot sandbox a worker, the run says so, and there is nothing
--- more to check -- unless the run is held to sandboxing
--- (COSMIC_SANDBOX=must, or CI's COSMIC_CI_REQUIRE_SANDBOX=1) and this
--- test is not itself in a sandbox, whose runs of its own the kernel
--- refuses one: then it fails. A test that runs this program
--- undeclared is refused it, sandboxed, and one that declares `tool`
--- runs again when the tool does.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local observations = require("build.filesystem_observations")
local Test = require("cosmic.test")

--- What a sandboxed run of `cosmic test` needs of the host, and the
--- program it runs.
Test.needs{
  host = { "/dev/urandom", "/etc", "/proc", "/usr/" },
  env = { "COSMIC_SANDBOX", "COSMIC_CI_REQUIRE_SANDBOX" },
  tool = true,
}

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- A checkout of the suite at `root`: a test that reads a declared
--- directory, one that reads a declared variable, one that loads a
--- module of the tree, one that declares the network, and a file
--- nothing declares.
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

Test.needs { network = { "127.0.0.1" } }

local function test_net()
  assert(true)
end
]]))
end

--- Whether a run that said `text` sandboxed no worker, where that is
--- allowed: false where it did sandbox them, and a failure where the run
--- is held to sandboxing and this test is in no sandbox of its own.
local function unsandboxed(text: string): boolean
  if not text:find("no worker can be sandboxed here", 1, true) then return false end
  local held = sys.getenv("COSMIC_SANDBOX") == "must" or
    sys.getenv("COSMIC_CI_REQUIRE_SANDBOX") == "1"
  local here, _ = sys.getcwd()
  assert(not held or here == "/tree", "the run is held to sandboxing, but " .. text)
  return true
end

--- The environment a sandboxed run of the suite is started with, its
--- shared cache at `cache`.
local function environment(cache: string): {string:string}
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = cache
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_TEST_NO_SHARED = nil
  env.COSMIC_SANDBOX = nil
  -- This run's own switch: off, the run it starts shares nothing.
  env.COSMIC_TEST_SANDBOX = sys.getenv("COSMIC_TEST_SANDBOX")
  env.FLAVOUR = "sweet"
  return env
end

--- Runs `cosmic test` on `root` with `words` after it, answering what it
--- printed, which must say it passed -- unless `unchecked`, for a run that
--- may have sandboxed nothing.
local function run(root: string, output: string, env: {string:string}, words?: {string},
                   unchecked?: boolean): string
  local fd = assert(Fs.open_write(output))
  local argv: {string} = { assert(Proc.executable()), "test" }
  for _, word in ipairs(words or {}) do argv[#argv + 1] = word end
  local result, trouble = Child.run(argv, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ms = 60000,
  })
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(unchecked or (result ~= nil and result.ok), tostring(trouble) .. text)
  return text
end

local function test_a_sandboxed_verdict_stands_until_what_it_declares_changes(tmp: string)
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
  if unsandboxed(first) then return end
  assert(first:find("4 ran, 0 stood", 1, true) and first:find("; sandboxed", 1, true), first)
  -- Nothing changed: all but the one that reaches the network stands,
  -- and none is assumed.
  local again = said("1 ran, 3 stood")
  assert(not again:find("assumed", 1, true), again)
  -- A file no test declares.
  assert(Fs.write(root .. "/suite/unrelated.txt", "changed\n"))
  said("1 ran, 3 stood")
  -- A file beneath a declared directory.
  assert(Fs.write(root .. "/suite/data/f", "two\n"))
  said("2 ran, 2 stood")
  -- A module of a test's closure.
  assert(Fs.write(root .. "/suite/lib.tl", "return { value = 2 }\n"))
  said("2 ran, 2 stood")
  -- A declared variable's value.
  env.FLAVOUR = "salty"
  said("2 ran, 2 stood")
  -- The declaration.
  local source = assert(Fs.read(root .. "/suite/data_test.tl"))
  assert(Fs.write(root .. "/suite/data_test.tl",
    (source:gsub('reads = { "suite/data/" }', 'reads = { "suite/data/", "suite/lib.tl" }'))))
  said("2 ran, 2 stood")
  -- Forced.
  said("4 ran, 0 stood", { "--all" })
  env.COSMIC_TEST_ALL = "1"
  said("4 ran, 0 stood")
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
  -- Told to stand on none of them, a checkout runs everything.
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
  assert(Fs.write(root .. "/suite/tool_test.tl", [[
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

Test.needs { tool = true, store = true }

local function test_runs_the_tool()
  local result = assert(Child.run({ assert(Proc.executable()), "-e", "" }))
  assert(result.ok)
end
]]))
  assert(Fs.write(root .. "/suite/undeclared_test.tl", [[
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

Test.needs { store = true }

local function test_is_refused_the_tool()
  local result, trouble = Child.run({ assert(Proc.executable()), "-e", "" })
  assert(result == nil, "the program ran undeclared")
  assert(trouble:find("ermission denied", 1, true), trouble)
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
local function test_a_verdict_whose_inputs_moved_as_it_ran_is_not_kept(tmp: string)
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/moving.txt", "one\n"))
  -- It says it started, and fails if what it reads moves within a
  -- few seconds.
  assert(Fs.write(root .. "/suite/moving_test.tl", [[
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/moving.txt" } }

local function test_moving(tmp: string)
  local was = Fs.read("suite/moving.txt")
  assert(Fs.write(tmp .. "/started", "yes"))
  local deadline = Time.monotonic_ns() + 3000000000
  while Time.monotonic_ns() < deadline do
    assert(Fs.read("suite/moving.txt") == was, "it moved")
    assert(Time.sleep_ns(50000000))
  end
end
]]))
  local env = environment(tmp .. "/cache/verdicts.db")
  env.COSMIC_VERDICT_CACHE = "0"
  assert(Fs.mkdirs(tmp .. "/t"))
  env.TMPDIR = assert(Fs.absolute(tmp .. "/t"))
  local first = run(root, tmp .. "/first.out", env)
  if unsandboxed(first) then return end
  assert(first:find("1 ran, 0 stood", 1, true), first)
  -- Forced, and moved as it runs: it fails.
  local fd = assert(Fs.open_write(tmp .. "/forced.out"))
  local handle = assert(Child.start({ assert(Proc.executable()), "test", "--all" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true,
  }))
  local deadline = Time.monotonic_ns() + 30000000000
  local started = false
  while not started and Time.monotonic_ns() < deadline do
    for _, entry in ipairs(Fs.list(tmp .. "/t") or {}) do
      if Fs.exists(tmp .. "/t/" .. entry .. "/real/started") then started = true end
    end
    if not started then assert(Time.sleep_ns(20000000)) end
  end
  assert(started, "the test never started")
  overwrite(root .. "/suite/moving.txt", "two\n")
  local result = assert(handle:wait(60000))
  assert(Fs.close(fd))
  local forced = assert(Fs.read(tmp .. "/forced.out"))
  assert(not result.ok and forced:find("it moved", 1, true), forced)
  -- Back as it was: the pass its first run kept is gone with the
  -- failure, so it runs; then it stands.
  overwrite(root .. "/suite/moving.txt", "one\n")
  local back = run(root, tmp .. "/back.out", env)
  assert(back:find("1 ran, 0 stood", 1, true), back)
  local stands = run(root, tmp .. "/stands.out", env)
  assert(stands:find("0 ran, 1 stood", 1, true), stands)
end
