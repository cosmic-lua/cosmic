--- The cases of cosmic/proc_test.tl about this very program: its path,
--- and the program it starts again or becomes. They declare `lua`
--- because they start this program, only to run a chunk.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local stand_in = require("build.stand_in")
local Test = require("cosmic.test")
local Time = require("cosmic.time")

--- The program itself, which its tests start to run a chunk (`lua`).
Test.needs{ lua = true }

--- The public wrapper and annotated syscall name the same directly executable
--- logical program. Native mode preserves the physical executable answer;
--- portable coverage supplies the artifact answer in ci/fixtures/identity_test.tl.
local function test_executable_wraps_the_public_syscall()
  local direct = assert(sys.executable())
  local wrapped = assert(Proc.executable())
  assert(wrapped == direct)
  assert(wrapped:sub(1, 1) == "/")
end

--- A relaunched child is this exact program: the same core image and
--- runtime identity, the same logical artifact, reached without the
--- launcher, and its startup accepts the contract it is handed.
local function test_relaunch_starts_this_same_program(tmp: string)
  local relaunch = Proc.relaunch()
  if relaunch == nil then return end -- a native start has nothing to relaunch
  assert(Proc.relaunch() == relaunch, "the relaunch description is kept")
  local chunk = 'local Proc = require("cosmic.proc") local Store = require("cosmic.store") ' ..
    'print(Store.meta("host_image"), Store.meta("runtime"), (Proc.executable()))'
  local started = this_program.program({ "-e", chunk }, { env = this_program.environment(), cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, tostring(r.stderr))
  local expected = table.concat({ assert(Store.meta("host_image")),
    assert(Store.meta("runtime")), (assert(Proc.executable())) }, "\t") .. "\n"
  assert(r.stdout == expected, tostring(r.stdout) .. " ~= " .. expected)
end

--- A program this one becomes starts with SIGPIPE at its default, as a
--- child it spawns does, even when this one ignored it: exec hands on
--- an ignored signal, and a pipeline downstream of it would never end.
local function test_exec_hands_on_sigpipe_at_its_default(tmp: string)
  if Proc.relaunch() == nil then return end -- a native start has nothing to relaunch
  if not Fs.exists("/proc/self/status") then return end -- nothing to ask
  -- The case is a process that ignored SIGPIPE itself. One started with
  -- it already ignored hands that on, as its parent chose, and so does
  -- everything it starts: a runner that ignores SIGPIPE has no case here.
  local own = assert(assert(Fs.read("/proc/self/status")):match("SigIgn:%s*(%x+)"))
  local own_mask = math.tointeger(tonumber(own, 16)) or 0
  if own_mask & (1 << (sys.SIGPIPE - 1)) ~= 0 then return end
  -- The program it becomes, and the child it feeds: a stand-in, which
  -- starts with no descriptors and no environment handed it, and says
  -- which signals it arrived ignoring.
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local chunk = [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local probe = ...
-- Feeding a child its input is what makes this process ignore
-- SIGPIPE, so a write to a child that has gone cannot end it.
local fed = assert(Child.start({ probe, "exit 0" }, { input = "" }))
assert(fed:wait())
local own = assert(assert(Fs.read("/proc/self/status")):match("SigIgn:%s*(%x+)"))
assert((math.tointeger(tonumber(own, 16)) or 0) & ]] .. "(1 << " .. tostring(sys.SIGPIPE - 1) .. ")" .. [[ ~= 0, "SIGPIPE is not ignored")
local _, trouble = Proc.exec({ probe, "status-field SigIgn" }, { env = {} })
print(trouble)
require("cosmic.sys").exit(1)
]]
  local started = this_program.program({ "-e", chunk, probe }, { env = this_program.environment(), cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, tostring(r.stdout) .. tostring(r.stderr))
  local ignored = assert(assert(r.stdout):match("SigIgn:%s*(%x+)"), r.stdout)
  local mask = math.tointeger(tonumber(ignored, 16)) or 0
  assert(mask & (1 << (sys.SIGPIPE - 1)) == 0, "SIGPIPE arrived ignored: " .. ignored)
end

--- What the program a chunk becomes answers to `env-of FOO`: `exec` is
--- the [`Proc.exec`] call it makes, `outer` the variable the chunk's own
--- process has.
local function becomes(tmp: string, probe: string, exec: string): string
  local chunk = 'local Proc = require("cosmic.proc")\nlocal probe = ...\n' ..
    "local _, trouble = " .. exec .. "\nprint(trouble)\nrequire(\"cosmic.sys\").exit(1)\n"
  local env = this_program.environment()
  env.FOO = "outer"
  local started = this_program.program({ "-e", chunk, probe }, { env = env, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, tostring(r.stdout) .. tostring(r.stderr))
  return r.stdout or ""
end

--- `Proc.exec(argv, { env })` is `Child.start(argv, { env })`'s, with the
--- process replaced: argv[1] the program, `env` its whole environment
--- and, left out, this process's own.
local function test_exec_takes_argv_and_the_whole_environment(tmp: string)
  if Proc.relaunch() == nil then return end -- a native start has nothing to relaunch
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local given = becomes(tmp, probe, 'Proc.exec({ probe, "env-of FOO" }, { env = { FOO = "given" } })')
  assert(given == "FOO=given\n", given)
  local replaced = becomes(tmp, probe, 'Proc.exec({ probe, "env-of FOO" }, { env = { OTHER = "x" } })')
  assert(replaced == "FOO unset\n", replaced)
  local inherited = becomes(tmp, probe, 'Proc.exec({ probe, "env-of FOO" })')
  assert(inherited == "FOO=outer\n", inherited)
  assert(not pcall(Proc.exec, {}))
  local missing = tmp .. "/missing"
  local failed, trouble = Proc.exec({ missing, "x" })
  assert(not failed and trouble:find(missing .. ": ", 1, true) == 1, trouble)
end

--- A relaunched child's arguments are the words after the relaunch's
--- own, without the `--artifact` pair the relaunch puts first, and its
--- relaunch names the directory it was started in, though it moved
--- since.
local function test_arguments_and_cwd_are_how_the_program_started(tmp: string)
  if Proc.relaunch() == nil then return end -- a native start has nothing to relaunch
  local chunk = "local Proc = require('cosmic.proc'); require('cosmic.sys').chdir('/'); " ..
    "print(table.concat(Proc.arguments(), '|')); print(assert(Proc.relaunch()).cwd)"
  local started = this_program.program({ "-e", chunk, "one", "two words" },
    { cwd = tmp, stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.code == 0, tostring(r.stderr))
  local real = assert(sys.realpath(tmp))
  assert(r.stdout == "-e|" .. chunk .. "|one|two words\n" .. real .. "\n", r.stdout)
end
