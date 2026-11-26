--- A script whose `#!` line names the core and its artifact runs as a
--- program of its own (core/startup.c). macOS reads and splits the line
--- otherwise, so the module requires Linux. The rest of startup's
--- adoption of a portable launch is core/startup_test.tl's.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local startup_fixture = require("build.startup_fixture")

--- The program itself, which its tests start past its launcher.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } }, requires = { "os:linux" } }

local relaunch_or_skip = startup_fixture.relaunch_or_skip
local argv_at = startup_fixture.argv_at
local run_relaunched = startup_fixture.run_relaunched

--- The one-argument form is what a `#!` line can carry: a script whose
--- first line names the core and its artifact runs as a program of its
--- own, handed its arguments. The whole line counts against what the
--- kernel reads of it -- 255 bytes on Linux since 5.1, 127 before -- so
--- the line names links in the test's directory, not the core's path in
--- the cache and the artifact's in the checkout, which together run past
--- it; a link to the artifact names its file as well as the path does.
local function test_a_script_names_the_core_as_its_interpreter(tmp: string)
  local relaunch = relaunch_or_skip()
  assert(Fs.symlink(argv_at(relaunch, 1), tmp .. "/c"))
  assert(Fs.symlink(argv_at(relaunch, 3), tmp .. "/a"))
  local line = "#!" .. tmp .. "/c --artifact=" .. tmp .. "/a"
  assert(#line <= 255, "the #! line is longer than the kernel reads: " .. line)
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, line .. "\n" .. [[
local Proc = require("cosmic.proc")

return function(argv: {string}): integer
  local executable, _ = Proc.executable()
  print(executable, table.concat(argv, "|"))
  return 0
end
]], 0x1ed))
  local r = run_relaunched(relaunch, { script, "a", "b c" })
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  assert(r.stdout == tmp .. "/a\ta|b c\n", tostring(r.stdout))
end
