--- core/startup.c's adoption of a portable launch: the core the
--- launcher executes checks what it was handed before any Lua runs. A
--- test runs its own launches, in processes of its own, past the
--- launcher; a host program has no launcher, so there is nothing here
--- for it to check. The launcher's own cache is
--- core/launcher_cache_test.tl's.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which its tests start past its launcher.
Test.needs{ tool = true }

local function environment(): {string:string}
  local env = this_program.environment()
  env.COSMIC_PORTABLE_STARTUP_TEST_READY = nil
  env.COSMIC_PORTABLE_STARTUP_TEST_GO = nil
  return env
end

--- Runs `argv` with the private contract `relaunch` hands a child.
local function run_relaunched(relaunch: Proc.Relaunch, argv: {string}): Child.Result
  local env = environment()
  for name, value in pairs(relaunch.env) do env[name] = value end
  return (assert(Child.run(argv, { env = env, fds = relaunch.fds,
    stdout = "capture", stderr = "capture", timeout_ms = 30000 })))
end

--- The core refuses an artifact it cannot name absolutely, before it
--- reads anything from it, and says why.
local function test_a_relative_artifact_path_is_refused()
  local relaunch = Proc.relaunch()
  if relaunch == nil or #relaunch.argv < 3 then return end
  local r = run_relaunched(relaunch, { relaunch.argv[1], relaunch.argv[2], "relative/artifact" })
  assert(r.code == 2, "exit " .. tostring(r.code))
  assert((assert(r.stderr)):find("cosmic: portable artifact path is not absolute",
    1, true), tostring(r.stderr))
end

local SHOW_EXECUTABLE <const> = "print(require('cosmic.proc').executable(), ...)"

--- `--artifact=<path>`, one argument, starts the runtime as `--artifact
--- <path>` does: the runtime's own arguments follow, and the program
--- names itself by the same path.
local function test_the_joined_artifact_argument_starts_as_the_two_argument_form()
  local relaunch = Proc.relaunch()
  if relaunch == nil or #relaunch.argv < 3 then return end
  local core, artifact = relaunch.argv[1], relaunch.argv[3]
  local joined = run_relaunched(relaunch,
    { core, "--artifact=" .. artifact, "-e", SHOW_EXECUTABLE, "a", "b c" })
  assert(joined.ok, "exit " .. tostring(joined.code) .. ": " .. tostring(joined.stderr))
  local split = run_relaunched(relaunch,
    { core, "--artifact", artifact, "-e", SHOW_EXECUTABLE, "a", "b c" })
  assert(split.ok, "exit " .. tostring(split.code) .. ": " .. tostring(split.stderr))
  assert(joined.stdout == artifact .. "\ta\tb c\n", tostring(joined.stdout))
  assert(joined.stdout == split.stdout, tostring(split.stdout))
end

--- `--artifact=` naming no path is refused as `--artifact` with no path
--- after it is, before anything runs.
local function test_the_joined_artifact_argument_without_a_path_is_refused()
  local relaunch = Proc.relaunch()
  if relaunch == nil or #relaunch.argv < 3 then return end
  local core = relaunch.argv[1]
  for _, argv in ipairs({ { core, "--artifact=", "-e", "print(1)" }, { core, "--artifact" } }) do
    local r = run_relaunched(relaunch, argv)
    assert(r.code == 2, argv[2] .. ": exit " .. tostring(r.code))
    assert(r.stdout == "", argv[2] .. ": " .. tostring(r.stdout))
    assert((assert(r.stderr)):find("cosmic: portable startup names no artifact", 1, true),
      argv[2] .. ": " .. tostring(r.stderr))
  end
end

--- The joined form's path must name the artifact its descriptor holds:
--- the kernel cuts a `#!` line past what it reads without a word, and the
--- program would then run under a name that is not its own.
local function test_a_joined_artifact_path_naming_another_file_is_refused(tmp: string)
  local relaunch = Proc.relaunch()
  if relaunch == nil or #relaunch.argv < 3 then return end
  local artifact = relaunch.argv[3]
  assert(Fs.write(tmp .. "/other", "not the artifact\n"))
  for _, path in ipairs({ artifact:sub(1, #artifact - 1), tmp .. "/other" }) do
    local r = run_relaunched(relaunch,
      { relaunch.argv[1], "--artifact=" .. path, "-e", "print(1)" })
    assert(r.code == 2, path .. ": exit " .. tostring(r.code))
    assert(r.stdout == "", path .. ": " .. tostring(r.stdout))
    assert((assert(r.stderr)):find(
      "cosmic: portable artifact path does not name the retained artifact", 1, true),
      path .. ": " .. tostring(r.stderr))
  end
end

--- The one-argument form is what a `#!` line can carry: a script whose
--- first line names the core and its artifact runs as a program of its
--- own, handed its arguments. The whole line counts against what the
--- kernel reads of it -- 255 bytes on Linux since 5.1, 127 before -- so
--- the line names links in the test's directory, not the core's path in
--- the cache and the artifact's in the checkout, which together run past
--- it; a link to the artifact names its file as well as the path does.
--- macOS reads and splits the line otherwise; only Linux's is checked.
local function test_a_script_names_the_core_as_its_interpreter(tmp: string)
  local names = assert(sys.uname())
  if names.sysname ~= "Linux" then return end
  local relaunch = Proc.relaunch()
  if relaunch == nil or #relaunch.argv < 3 then return end
  assert(Fs.symlink(relaunch.argv[1], tmp .. "/c"))
  assert(Fs.symlink(relaunch.argv[3], tmp .. "/a"))
  local line = "#!" .. tmp .. "/c --artifact=" .. tmp .. "/a"
  assert(#line <= 255, "the #! line is longer than the kernel reads: " .. line)
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, line .. "\n" .. [[
local Proc = require("cosmic.proc")

return function(argv: {string}): integer
  print(Proc.executable(), table.concat(argv, "|"))
  return 0
end
]], 0x1ed))
  local r = run_relaunched(relaunch, { script, "a", "b c" })
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  assert(r.stdout == tmp .. "/a\ta|b c\n", tostring(r.stdout))
end
