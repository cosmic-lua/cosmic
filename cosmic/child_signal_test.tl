--- A signal this process started ignoring stays ignored under a guard:
--- the one case of cosmic.child whose child starts with SIGINT ignored,
--- which only a shell's `trap '' INT` sets up here.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

--- The system's sh, which ignores SIGINT for the program it execs, and
--- the program itself, through its launcher.
Test.needs{ tool = true, system = true }

local function nested_cosmic_environment(): {string:string}
  local environment = Env.all()
  -- These hooks belong to the portable test's outer Cosmic startups. A
  -- nested fixture has no matching FIFO handshake and must not inherit them.
  environment.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  environment.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  return environment
end

--- A signal this process ignores -- `cosmic test &` from a script, whose
--- shell ignores SIGINT for it -- is not the guard's to catch.
local function test_guard_leaves_an_ignored_signal_ignored(tmp: string)
  local report = tmp .. "/report"
  local fixture = tmp .. "/ignoring.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local guard = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  local caught = guard:cancelled()
  assert(guard:close())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  assert(Fs.write(argv[1], tostring(caught)))
  return 0
end
]]))
  -- TODO: start the fixture with SIGINT ignored in cosmic, through
  -- build.this_program's `program`, once cosmic.sys can set a signal's
  -- disposition, and move this case back to cosmic/child_test.tl.
  local r = assert(Child.run({ "/bin/sh", "-c", "trap '' INT; exec \"$0\" \"$@\"",
    assert(Proc.executable()), fixture, report },
    { env = nested_cosmic_environment(), stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
      " " .. tostring(r.stderr))
  local got = Fs.read(report)
  assert(got == "0", tostring(got))
end
