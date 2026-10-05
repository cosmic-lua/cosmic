--- End to end: what a module of a project requires of the host
--- ([`Test.policy`]'s `requires`) decides, before any worker starts,
--- whether its tests run, are skipped, are not applicable or fail, in the
--- summary and the listing of the `cosmic test` that ran them. A module
--- whose requirement is absent is never loaded, is keyed by none and keeps no
--- verdict; one whose requirements are present runs under a key that holds
--- what the host answered. Each run here is unsandboxed
--- (COSMIC_TEST_SANDBOX=0), so it means the same on every host, and a
--- held run (COSMIC_SANDBOX=must, COSMIC_CI_REQUIRE_SANDBOX=1) fails for none
--- of the host's absences.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A project with a module that requires a program, and a test that passes:
--- the program is the one `tool` names in bin/, which a PATH of that
--- directory alone finds.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/bin"))
  assert(Fs.write(root .. "/prog_test.tl", [[
local Test = require("cosmic.test")
Test.policy { profiles = { "system" }, env = { "PATH" }, requires = { "program:requires-fake-tool" } }

local function test_passes() assert(true) end
local function test_passes_too() assert(true) end
]]))
  return root
end

--- Puts the fake program in `root`'s bin/, holding `text`, or removes it.
local function tool(root: string, text: string | nil)
  local path = root .. "/bin/requires-fake-tool"
  if text == nil then
    local _, _ = Fs.remove(path)
    return
  end
  assert(Fs.write(path, text))
  assert(Fs.chmod(path, tonumber("755", 8) as integer))
end

--- What `cosmic test` in `root` printed and its status, run unsandboxed
--- with `extra` set in its environment, and PATH the project's bin/ alone.
local function run(root: string, extra?: {string:string}): string, integer
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_SANDBOX = nil
  env.COSMIC_CI_REQUIRE_SANDBOX = nil
  env.PATH = root .. "/bin"
  for name, value in pairs(extra or {}) do env[name] = value end
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(90),
  })
  local result = assert(Child.run(started.argv, started.options))
  return (result.stdout or "") .. (result.stderr or ""), result.code
end

--- A present requirement lets the module run, under a key that holds the
--- answer: the program's bytes moving runs the tests again, and the
--- same bytes stand.
local function test_a_present_requirement_runs_and_its_answer_keys_the_verdict(tmp: string)
  local root = project(tmp)
  tool(root, "one\n")
  local out, code = run(root)
  assert(code == 0, out)
  assert(out:find("2 tests, 1 module; 2 ran, 0 stood, ", 1, true), out)
  assert(not out:find("skipped", 1, true) and not out:find("n/a", 1, true), out)
  out, code = run(root)
  assert(code == 0, out)
  assert(out:find("; 0 ran, 2 stood, ", 1, true), out)
  tool(root, "two\n")
  out, code = run(root)
  assert(code == 0, out)
  assert(out:find("; 2 ran, 0 stood, ", 1, true), out)
end

--- An absent program skips the module's tests without loading it, keeps no
--- verdict, and no held run fails for it: it is the host's, which no
--- leg has promised.
local function test_an_absent_program_skips_the_module_and_keeps_no_verdict(tmp: string)
  local root = project(tmp)
  tool(root, "one\n")
  local _, _ = run(root)
  tool(root, nil)
  assert(Fs.write(root .. "/prog_test.tl", [[
local Test = require("cosmic.test")
Test.policy { profiles = { "system" }, env = { "PATH" }, requires = { "program:requires-fake-tool" } }
error("a module with an absent requirement must not load")
local function test_passes() assert(true) end
local function test_passes_too() assert(true) end
]]))
  for _, extra in ipairs({ {}, {}, { COSMIC_SANDBOX = "must" }, { COSMIC_CI_REQUIRE_SANDBOX = "1" } }) do
    local out, code = run(root, extra)
    assert(code == 0, out)
    assert(out:find("test: SKIP  prog_test test_passes: requires program:requires-fake-tool: ", 1, true), out)
    assert(out:find("test: SKIP  prog_test test_passes_too: requires program:requires-fake-tool: ", 1, true), out)
    assert(out:find("2 tests, 1 module; 2 ran, 0 stood, 2 skipped ", 1, true), out)
    assert(not out:find("must not load", 1, true), out)
  end
end

--- A requirement the platform never has makes the module not applicable:
--- counted apart from skipped, listed `N/A`, kept as no verdict, and no run
--- fails for it. COSMIC_TEST_PLATFORM=other makes the platform one without
--- Linux's requirements, which no Linux host is.
local function test_a_requirement_the_platform_lacks_is_not_applicable(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/nest_test.tl", [[
local Test = require("cosmic.test")
Test.policy { promises = { "nest" } }
error("a module that is not applicable must not load")
local function test_a() assert(true) end
local function test_b() assert(true) end
]]))
  assert(Fs.write(root .. "/plain_test.tl", [[
local function test_c() assert(true) end
]]))
  for i, extra in ipairs({ {}, {}, { COSMIC_SANDBOX = "must" }, { COSMIC_CI_REQUIRE_SANDBOX = "1" } }) do
    extra.COSMIC_TEST_PLATFORM = "other"
    local out, code = run(root, extra)
    assert(code == 0, out)
    -- `nest` is implied by the promise, and a platform without Linux never has it.
    assert(out:find("test: N/A  nest_test test_a: requires nest: nest: this platform has none\n", 1, true), out)
    assert(out:find("test: N/A  nest_test test_b: requires nest: ", 1, true), out)
    -- The module that applies runs once and then stands (a held run is keyed
    -- apart, and runs); the other has no verdict to stand on, and is marked
    -- not applicable each time.
    if i <= 2 then
      assert(out:find("3 tests, 2 modules; " .. (i == 1 and "1 ran, 0 stood" or "0 ran, 1 stood") .. ", ",
        1, true), out)
    end
    assert(out:find(", 2 n/a (this platform has none of what they check), ", 1, true), out)
    assert(not out:find("skipped", 1, true) and not out:find("must not load", 1, true), out)
  end
end

--- What a policy implies is required without being written: a grant of
--- /proc asks for `proc`, which the host has or has not, and the report
--- names it either way.
local function test_a_proc_grant_requires_proc(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/proc_test.tl", [[
local Test = require("cosmic.test")
Test.policy { grants = { { path = "/proc/self/status", letters = "r" } } }
local function test_a() assert(true) end
]]))
  local out, code = run(root)
  assert(code == 0, out)
  if Fs.exists("/proc/self") == true then
    assert(out:find("1 test, 1 module; 1 ran, 0 stood, ", 1, true), out)
  else
    assert(out:find("requires proc: ", 1, true) and out:find("1 n/a", 1, true), out)
  end
end

--- A name the table does not have fails the build, naming the rule, and
--- nothing runs.
local function test_an_unknown_requirement_fails_the_build(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/typo_test.tl", [[
local Test = require("cosmic.test")
Test.policy { requires = { "sandbxo" } }
local function test_a() assert(true) end
]]))
  local out, code = run(root)
  assert(code ~= 0, out)
  assert(out:find("unknown requirement \"sandbxo\"", 1, true), out)
  assert(not out:find("test: PASS", 1, true), out)
end

--- A requirement that is no more than what the policy implies, or a path or
--- a program the worker is given no way to see, fails the build too.
local function test_a_requirement_the_worker_could_not_use_fails_the_build(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/redundant_test.tl", [[
local Test = require("cosmic.test")
Test.policy { promises = { "nest" }, requires = { "nest" } }
local function test_a() assert(true) end
]]))
  local out, code = run(root)
  assert(code ~= 0, out)
  assert(out:find("\"nest\" is redundant: the promise \"nest\" implies it", 1, true), out)
  assert(Fs.write(root .. "/redundant_test.tl", [[
local Test = require("cosmic.test")
Test.policy { requires = { "path:/etc/hostname" } }
local function test_a() assert(true) end
]]))
  out, code = run(root)
  assert(code ~= 0, out)
  assert(out:find("needs a host grant of the path", 1, true), out)
end
