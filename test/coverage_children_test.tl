--- Processes a test starts report the core's C they ran (see
--- `Coverage.children`): the core carries the directory to each process
--- it starts, whatever environment the program gives it, and the
--- process never sees it. Run a level down, in a process of its own, so
--- the directory is this test's rather than its worker's.

local Child = require("cosmic.child")
local Coverage = require("cosmic.coverage")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

local function environment(): {string:string}
  local env = Env.all()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  env.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  return env
end

local function test_a_started_process_reports_its_c(tmp: string)
  if next(Coverage.native_lines()) == nil then return end
  local reports = tmp .. "/reports"
  assert(Fs.mkdirs(reports))
  assert(Fs.mkdirs(tmp .. "/parent"))
  assert(Fs.mkdirs(tmp .. "/child"))
  assert(Fs.write(tmp .. "/child/child.tl", [[
local Env = require("cosmic.env")
return function(): integer
  print(Env.get("COSMIC_COVERAGE_CHILDREN") == nil and "unseen" or "seen")
  return 0
end
]]))
  assert(Fs.write(tmp .. "/parent/parent.tl", [[
local Child = require("cosmic.child")
local Coverage = require("cosmic.coverage")
local Proc = require("cosmic.proc")
return function(argv: {string}): integer
  Coverage.children(argv[1])
  -- An empty environment: only the core can carry the directory.
  local r = assert(Child.run({ assert(Proc.executable()), argv[2] },
    { env = {}, cwd = argv[3], stdout = "capture", stderr = "capture",
      timeout_ms = 30000 }))
  assert(r.ok, tostring(r.stderr))
  print(assert(r.stdout):match("^(%a+)"))
  return 0
end
]]))
  local r = assert(Child.run({ assert(Proc.executable()), "parent.tl", reports,
    tmp .. "/child/child.tl", tmp .. "/child" },
    { env = environment(), cwd = tmp .. "/parent", stdout = "capture",
      stderr = "capture", timeout_ms = 60000 }))
  assert(r.ok, tostring(r.stderr))
  assert(r.stdout == "unseen\n", "the child saw the directory: " .. tostring(r.stdout))
  local main_lines = 0
  for _, name in ipairs((assert(Fs.list(reports)))) do
    for _ in (assert(Fs.read(reports .. "/" .. name))):gmatch("core/main%.c\t%d+\n") do
      main_lines = main_lines + 1
    end
  end
  assert(main_lines > 0, "the child reported no line of core/main.c")
end
