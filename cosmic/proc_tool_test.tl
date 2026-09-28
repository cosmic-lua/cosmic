--- The cases of cosmic/proc_test.tl about this very program: its path,
--- and the program it starts again or becomes. They declare `tool`
--- because they start this program or ask for its path.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local stand_in = require("build.stand_in")
local Test = require("cosmic.test")

--- The program itself, which its tests start.
Test.needs{ tool = true }

--- The public wrapper and annotated syscall name the same directly executable
--- logical program. Native mode preserves the physical executable answer;
--- portable coverage supplies the artifact answer in identity_test.tl.
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
  local script = tmp .. "/identity.tl"
  assert(Fs.write(script, [[
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
return function(): integer
  print(Store.meta("host_image"), Store.meta("runtime"), (Proc.executable()))
  return 0
end
]]))
  local started = this_program.program({ script }, { env = this_program.environment(), cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 })
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
  local script = tmp .. "/becomes.tl"
  assert(Fs.write(script, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
return function(argv: {string}): integer
  local probe = argv[1]
  -- Feeding a child its input is what makes this process ignore
  -- SIGPIPE, so a write to a child that has gone cannot end it.
  local fed = assert(Child.start({ probe, "exit 0" }, { input = "" }))
  assert(fed:wait())
  local own = assert(assert(Fs.read("/proc/self/status")):match("SigIgn:%s*(%x+)"))
  assert((math.tointeger(tonumber(own, 16)) or 0) & ]] .. "(1 << " .. tostring(sys.SIGPIPE - 1) .. ")" .. [[ ~= 0, "SIGPIPE is not ignored")
  local _, trouble = Proc.exec(probe, { probe, "status-field SigIgn" }, {})
  print(trouble)
  return 1
end
]]))
  local started = this_program.program({ script, probe }, { env = this_program.environment(), cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, tostring(r.stdout) .. tostring(r.stderr))
  local ignored = assert(assert(r.stdout):match("SigIgn:%s*(%x+)"), r.stdout)
  local mask = math.tointeger(tonumber(ignored, 16)) or 0
  assert(mask & (1 << (sys.SIGPIPE - 1)) == 0, "SIGPIPE arrived ignored: " .. ignored)
end
