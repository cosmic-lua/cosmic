--- RLIMIT_NOFILE as a start raises it (core/syscalls.c's
--- `cosmic_raise_descriptor_limit`): a process started with a soft
--- limit as low as macOS's default of 256 relaunches this program,
--- which takes descriptors past 256, and a host program it starts gets
--- the limit it started with back.

local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
--- What the chunk the program runs requires besides.
local type _ = require("cosmic.env")
local Clock = require("cosmic.clock")

--- `system` for /bin/sh, whose `ulimit` starts the program at a low
--- limit and says the limit a host program is given. `tool` for the
--- program, which the shell starts: `lua`, which holds only what the
--- tests start themselves, is refused beside `system`.
Test.policy{ profiles = { "system", "cosmic" } }

--- The soft limit the program is started at.
local LOW <const> = 256

--- Run in the program started at LOW: its own soft limit, what a
--- relaunch of it printed or why it failed, the soft limit a shell it
--- starts is given, its own once the two have started, and the shell's
--- again once it set its own.
local CHUNK <const> = [[
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local function shell_limit()
  local r = assert(Child.run({ "/bin/sh", "-c", "ulimit -Sn" }, { stdout = "capture" }))
  return (assert(r.stdout):gsub("%s+$", ""))
end
local limits = assert(sys.getrlimit(sys.RLIMIT_NOFILE))
print(limits.soft)
local relaunch = assert(Proc.relaunch())
local argv = {}
for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
argv[#argv + 1] = "-e"
argv[#argv + 1] = "print('relaunched')"
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
local r, why = Child.run(argv, { env = env, fds = relaunch.fds, stdout = "capture",
  stderr = "capture" })
print(r ~= nil and (assert(r.stdout):gsub("%s+$", "")) or why)
print(shell_limit())
print(assert(sys.getrlimit(sys.RLIMIT_NOFILE)).soft)
assert(sys.setrlimit(sys.RLIMIT_NOFILE, 300, limits.hard))
print(shell_limit())
]]

--- The lines the program printed running `chunk`, started by the shell at a soft limit
--- of LOW; nil where this host's hard limit leaves no room to raise it,
--- or where there is no artifact to relaunch.
local function started_low(tmp: string, chunk: string): {string} | nil
  if Proc.relaunch() == nil then return nil end -- a native start has nothing to relaunch
  local limits = assert(sys.getrlimit(sys.RLIMIT_NOFILE))
  if limits.hard < 2 * LOW then return nil end
  local started = this_program.program({ "-e", chunk }, { env = this_program.environment(),
    cwd = tmp, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local argv = { "/bin/sh", "-c", 'ulimit -Sn "$0" && exec "$@"', tostring(LOW) }
  for _, word in ipairs(started.argv) do argv[#argv + 1] = word end
  local r = assert(Child.run(argv, started.options))
  assert(r.code == 0, tostring(r.stdout) .. tostring(r.stderr))
  local lines: {string} = {}
  for line in assert(r.stdout):gmatch("[^\n]+") do lines[#lines + 1] = line end
  return lines
end

--- A program started at a soft limit of 256 raises it, and relaunches:
--- the relaunch hands its child descriptor 255, and places its own
--- above it, which a soft limit of 256 refuses.
local function test_a_start_at_a_low_limit_raises_it_and_relaunches(tmp: string)
  local lines = started_low(tmp, CHUNK)
  if lines == nil then return end
  assert(lines[2] == "relaunched", lines[2])
  local raised = assert(math.tointeger(tonumber(lines[1])), lines[1])
  assert(raised > LOW, "the soft limit stayed " .. lines[1])
end

--- A start that gives its child the limit the program started with
--- gives this program its raised one back once the child has started.
local function test_a_start_leaves_this_program_s_limit_raised(tmp: string)
  local lines = started_low(tmp, CHUNK)
  if lines == nil then return end
  assert(lines[4] == lines[1], tostring(lines[4]) .. " after starting, not " .. lines[1])
end

--- A host program gets the limit the program started with, not the one
--- it raised; once the program sets the limit, it gets that one.
local function test_a_host_program_gets_the_limit_the_program_started_with(tmp: string)
  local lines = started_low(tmp, CHUNK)
  if lines == nil then return end
  assert(lines[3] == tostring(LOW), lines[3])
  assert(lines[5] == "300", lines[5])
end

--- A program the process becomes ([`Proc.exec`], the execve binding) gets
--- the limit the process started with too.
local function test_a_program_exec_d_gets_the_limit_the_process_started_with(tmp: string)
  local lines = started_low(tmp, [[
local Proc = require("cosmic.proc")
local _, trouble = Proc.exec({ "/bin/sh", "-c", "ulimit -Sn" })
error(trouble)
]])
  if lines == nil then return end
  assert(lines[1] == tostring(LOW), tostring(lines[1]))
end
