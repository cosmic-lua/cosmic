--- Projects and assertions shared by the runner's deadline isolation tests.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Clock = require("cosmic.clock")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local this_program = require("build.this_program")
local stand_in = require("build.stand_in")
local confine = require("build.confine")

local record fixture
end

--- The environment a run of `cosmic test` these tests start is given:
--- its workers unsandboxed (`COSMIC_TEST_SANDBOX=0`), since what they
--- check is the runner's own handling of what a worker reads and leaves
--- of the host, which a sandbox would not let it reach.
function fixture.environment(): {string:string}
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  return env
end

function fixture.invoke(root: string, output: string, args: {string},
                        env?: {string:string}): Child.Result
  local words: {string} = { "test" }
  for _, value in ipairs(args) do words[#words + 1] = value end
  local fd = assert(Fs.open_write(output))
  local started = this_program.program(words, {
    cwd = root, env = env or fixture.environment(), stdout = fd, stderr = fd, timeout_ns = Clock.seconds(60),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  return (assert(result, trouble))
end

--- A hung test that also started a process group of its own, which the
--- end of its worker's group does not reach -- the stand-in `probe`,
--- placed at the project's bin/probe and named by `marker`, which it
--- keeps running; a test that ends its own process after printing; and
--- a quiet one that passes. With no `probe`, the hung test spins without
--- starting any child.
function fixture.project(tmp: string, marker: string, probe?: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  if probe ~= nil then
    assert(Fs.mkdirs(root .. "/bin"))
    assert(stand_in.place(probe, root .. "/bin/probe"))
  end
  local hang = [[
local Child = require("cosmic.child")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.policy { grants = { { path = "bin/probe", letters = "r" } } }

local held: {Child.Handle} = {}
local function test_hangs()
  held[1] = assert(Child.start({ "bin/probe", "sleep-forever", "MARKER" }))
  -- Still running a moment on, so what is found gone below was there:
  -- a probe that never started, or ended at once, fails this instead
  -- of timing out.
  local _, _ = sys.nanosleep(300 * 1000 * 1000)
  local state = assert(held[1]:try_wait())
  assert(not state.finished, "the probe is not running")
  while true do end
end
]]
  if probe == nil then hang = "local function test_hangs() while true do end end\n" end
  assert(Fs.write(root .. "/suite/hang_test.tl", (hang:gsub("MARKER", marker))))
  assert(Fs.write(root .. "/suite/exits_test.tl", [[
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local function test_exits()
  Fs.put(Fs.stdout, "said something\n")
  Proc.exit(0)
end
]]))
  assert(Fs.write(root .. "/suite/fine_test.tl", [[
local Fs = require("cosmic.fs")
local function test_fine()
  Fs.put(Fs.stdout, "quiet\n")
end
]]))
  return root
end

--- The processes /proc lists whose command line holds `marker`: every
--- one this process can see, in its own pid namespace and those
--- beneath it.
local function running(marker: string): {string}
  local found: {string} = {}
  local names, _ = Fs.list("/proc")
  for _, name in ipairs(names or {}) do
    if name:match("^%d+$") ~= nil then
      local read, _ = Fs.read("/proc/" .. name .. "/cmdline")
      local line = read or ""
      if line:find(marker, 1, true) ~= nil then found[#found + 1] = name end
    end
  end
  return found
end

--- Checks deadline isolation in the selected worker mode. With `probe`, the hung
--- worker also leaves an orphan in its own group: its caller requires the
--- kernel's children list, which lets the runner find and end that orphan.
function fixture.hung_runs(tmp: string, probe: string, sandbox_workers: boolean)
  -- Why the sandboxed case ran unsandboxed, which skips the test once
  -- that case has checked what the unsandboxed one does. The workers
  -- nest in this test's own sandbox, which a host may refuse: the
  -- kernel lets root nest one only two deep (core/syscalls.c's
  -- `map_ids`). CI's unprivileged runners nest them.
  local unsandboxed: string = nil
  for _, mode in ipairs({ sandbox_workers and "" or "0" }) do
    local marker = "cosmic-hang-" .. tostring(Clock.monotonic_ns())
    local here = tmp .. "/mode" .. mode
    local root = fixture.project(here, marker, probe)
    local output = here .. "/run.out"
    -- The failing tests' directories are kept; they are kept here.
    local env = fixture.environment()
    env.TMPDIR = here .. "/temp"
    env.COSMIC_TEST_SANDBOX = mode
    assert(Fs.mkdirs(env.TMPDIR))
    local started = Clock.monotonic_ns()
    -- Every test's deadline counts from its worker's start, so the two
    -- that end on their own must load and finish inside it too: two
    -- seconds leaves a slow host room inside this test's own deadline.
    local result = fixture.invoke(root, output, { "--timeout", "2", "--jobs", "2" }, env)
    local text = assert(Fs.read(output))
    assert(not result.ok, text)
    assert(Clock.monotonic_ns() - started < Clock.seconds(30), text)
    assert(text:find("suite.hang_test test_hangs: timed out after 2 s", 1, true), text)
    assert(text:find("suite.exits_test test_exits: the test process exited with status 0 " ..
        "before it reported", 1, true), text)
    assert(text:find("  | said something", 1, true), text)
    assert(not text:find("quiet", 1, true), text)
    assert(text:find("2 of 3 failed", 1, true), text)
    local sandboxed = text:find("; sandboxed", 1, true) ~= nil
    if mode == "0" then
      assert(not sandboxed, text)
    elseif not sandboxed and assert(sys.uname()).sysname == "Linux" then
      unsandboxed = confine.unsandboxed_reason(text)
    end
    assert(text:find(sandboxed and "its pid namespace was ended" or "its process group was ended",
      1, true), text)
    -- Where the runner can find what a dead worker left behind (Linux),
    -- the process the hung test left running is gone too.
    if probe ~= nil then
      local left = running(marker)
      assert(#left == 0, mode .. ": left running: " .. table.concat(left, " "))
    end
  end
  if unsandboxed ~= nil then Test.skip(unsandboxed) end
end

return fixture
