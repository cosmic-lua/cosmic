--- What the tests of core/startup.c's adoption of a portable launch share
--- (core/startup_test.tl, core/startup_script_test.tl): the relaunch they
--- start the program again by, and its argv. Test support.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

local record startup_fixture
end

--- This program's environment, without the startup tests' handshake.
function startup_fixture.environment(): mut {string:string}
  local env = Test.environment()
  env["COSMIC_PORTABLE_STARTUP_TEST_READY"] = nil
  env["COSMIC_PORTABLE_STARTUP_TEST_GO"] = nil
  return env
end

--- This start's relaunch, skipping the test where it has none or its argv
--- names no artifact (a host program, or a start with nothing to relaunch).
function startup_fixture.relaunch_or_skip(): Proc.Relaunch
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then Test.skip("this program has no relaunch to start again") end
  local found = assert(relaunch, "Test.skip ends the test where there is no relaunch")
  if #found.argv < 3 then
    Test.skip("this relaunch names no artifact: its argv is " .. table.concat(found.argv, " "))
  end
  return found
end

--- Word `i` of the argv a relaunch starts: the core, `--artifact`, the artifact.
function startup_fixture.argv_at(relaunch: Proc.Relaunch, i: integer): string
  local word = assert(relaunch.argv[i], "a relaunch's argv holds word " .. tostring(i))
  return word
end

--- Runs `argv` with the private contract `relaunch` hands a child.
function startup_fixture.run_relaunched(relaunch: Proc.Relaunch, argv: {string}): Child.Result
  local env = startup_fixture.environment()
  for name, value in pairs(relaunch.env) do env[name] = value end
  return (assert(Child.run(argv, { env = env, fds = relaunch.fds,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })))
end

return startup_fixture
