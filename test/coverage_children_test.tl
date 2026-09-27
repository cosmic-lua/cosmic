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
local Test = require("cosmic.test")

--- What a confined child is given of the host, and /proc, where its
--- coverage is found.
Test.needs{ host = { "/proc", "/usr" }, tool = true }

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

local function environment(): {string:string}
  local env = observations.environment()
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

--- A process confined in a pid namespace of its own, and one it confines
--- in turn, each pid 2 of its namespace, report apart: neither takes the
--- other's report for its own and leaves it. Where the kernel gives the
--- first no /proc of its own (a container masking parts of its /proc),
--- it cannot confine the second, and there is nothing to check.
local function test_processes_confined_apart_report_apart(tmp: string)
  if next(Coverage.native_lines()) == nil then return end
  if Proc.relaunch() == nil then return end -- no portable artifact to start again
  local reports = tmp .. "/reports"
  assert(Fs.mkdirs(reports))
  assert(Fs.mkdirs(tmp .. "/parent"))
  -- The inner process, this program again, is given what it needs to
  -- start -- the system's libraries too, for a core linked dynamically,
  -- as the checked one is -- and the directory it reports to.
  local reads: {string} = {}
  for _, path in ipairs(observations.itself()) do reads[#reads + 1] = path end
  for _, path in ipairs({ "/usr", "/lib", "/lib64", "/proc", "/dev/null" }) do
    if Fs.exists(path) then reads[#reads + 1] = path end
  end
  assert(Fs.write(tmp .. "/parent/parent.tl", [[
local Coverage = require("cosmic.coverage")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local type Searcher = function(string): any, any
local record Status
  code: integer
end
local record Process
  spawn: function(string, {string}, {string:string}, string, integer, integer, integer, boolean,
    {integer:integer}, any): integer, string, integer
  waitpid: function(integer, boolean): Status
end
return function(argv: {string}): integer
  local reports, reads: string, {string} = argv[1], {}
  for path in argv[2]:gmatch("[^\n]+") do reads[#reads + 1] = path end
  Coverage.children(reports)
  local process: Process = nil
  for _, searcher in ipairs(package.searchers as {Searcher}) do
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then process = extra as Process end
  end
  local relaunch = assert(Proc.relaunch())
  local words: {string} = {}
  for _, word in ipairs(relaunch.argv) do words[#words + 1] = word end
  words[#words + 1] = "-e"
  words[#words + 1] = "return 0"
  local fds: {integer:integer} = {}
  for target, source in pairs(relaunch.fds) do fds[target] = source end
  local own = sys.stat("/proc/sys") == nil
  local pid, trouble, errno = process.spawn(words[1], words, relaunch.env, "/", nil, nil, nil,
    false, fds, { unveil = { reads = reads, writes = { reports } }, offline = true })
  if pid == nil then
    local unconfinable = errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
      errno == sys.EINVAL or errno == sys.ENOSPC
    print((unconfinable and "unconfinable " or own and "refused " or "host-proc ") .. trouble)
    return 0
  end
  print("exited " .. tostring(process.waitpid(pid, false).code))
  return 0
end
]]))
  local r = assert(Child.run({ assert(Proc.executable()), "parent.tl", reports,
    table.concat(reads, "\n") },
    { env = environment(), cwd = tmp .. "/parent", stdout = "capture",
      stderr = "capture", timeout_ms = 60000 }))
  assert(r.ok, tostring(r.stderr))
  local said = assert(r.stdout)
  if said:find("^host%-proc ") then return end
  -- A kernel that confines nothing (no user namespaces for this user, or
  -- no Linux: ENOSYS), as the sandbox's other tests take it: a failure
  -- only under COSMIC_SANDBOX=must.
  if said:find("^unconfinable ") then
    assert(Env.get("COSMIC_SANDBOX") ~= "must", "COSMIC_SANDBOX=must, but: " .. said)
    return
  end
  assert(said == "exited 0\n", said)
  -- The parent's report and the process's it confined.
  local reported = 0
  for _, name in ipairs((assert(Fs.list(reports)))) do
    if (assert(Fs.read(reports .. "/" .. name))):find("core/main%.c\t%d+\n") then
      reported = reported + 1
    end
  end
  assert(reported == 2, tostring(reported) .. " reports of 2")
end

--- A process reports only to a directory named by a core of its own
--- build: the variable carries the naming core's signature, and one
--- another build's core named -- or one with none, as a release before
--- the signature names it -- is passed on but never reported to, since
--- that core's lines are another build's C (bin/zig's pinned release,
--- started by a test, is such a core).
local function test_a_process_of_another_build_does_not_report(tmp: string)
  if next(Coverage.native_lines()) == nil then return end
  for index, value in ipairs({ "0000000000000000:" .. tmp .. "/foreign",
      tmp .. "/unsigned" }) do
    local dir = value:match("[^:]*$")
    assert(Fs.mkdirs(dir))
    local env = environment()
    env.COSMIC_COVERAGE_CHILDREN = value
    local r = assert(Child.run({ assert(Proc.executable()), "-e", "return 0" },
      { env = env, cwd = tmp, stdout = "capture", stderr = "capture", timeout_ms = 60000 }))
    assert(r.ok, tostring(r.stderr))
    local names = assert(Fs.list(dir))
    assert(#names == 0, tostring(index) .. ": a report of another build's core: " ..
      table.concat(names, ", "))
  end
end
