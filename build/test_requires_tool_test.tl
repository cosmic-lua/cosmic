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
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A project with a module that requires a file of the host, `tool` in its
--- root, and two tests that pass.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  return root
end

--- A directory of the host outside the project's tree, for what a module requires.
local function outside(tmp: string): string
  assert(Fs.mkdirs(tmp .. "/host"))
  return tmp .. "/host"
end

--- Writes the module `name`, which requires `file` and grants it.
local function module(root: string, name: string, file: string, extra?: string)
  assert(Fs.write(root .. "/" .. name .. "_test.tl", 'local Test = require("cosmic.test")\n' ..
      'Test.policy { grants = { { path = "' .. file .. '", letters = "r" } }, ' ..
      'requires = { "path:' .. file .. '" } }\n' .. (extra or "") ..
      "local function test_passes() assert(true) end\n" ..
      "local function test_passes_too() assert(true) end\n"))
end

--- What `cosmic test` in `root` printed and its status, run unsandboxed
--- with `extra` set in its environment.
local function run(root: string, extra?: {string:string}): string, integer
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_SANDBOX = nil
  env.COSMIC_CI_REQUIRE_SANDBOX = nil
  for name, value in pairs(extra or {}) do env[name] = value end
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(90),
  })
  local result = assert(Child.run(started.argv, started.options))
  return (result.stdout or "") .. (result.stderr or ""), result.code
end

--- A present requirement lets the module run, under a key that holds the
--- answer: the file's bytes moving runs the tests again, and the same bytes
--- stand.
local function test_a_present_requirement_runs_and_its_answer_keys_the_verdict(tmp: string)
  local root = project(tmp)
  local file = outside(tmp) .. "/tool"
  module(root, "prog", file)
  assert(Fs.write(file, "one\n"))
  local out, code = run(root)
  assert(code == 0, out)
  assert(out:find("2 tests, 1 module; 2 ran, 0 stood, ", 1, true), out)
  assert(not out:find("skipped", 1, true) and not out:find("n/a", 1, true), out)
  out, code = run(root)
  assert(code == 0, out)
  assert(out:find("; 0 ran, 2 stood, ", 1, true), out)
  assert(Fs.write(file, "two\n"))
  out, code = run(root)
  assert(code == 0, out)
  assert(out:find("; 2 ran, 0 stood, ", 1, true), out)
end

--- An absent file skips the module's tests without loading it, keeps no
--- verdict, and no held run fails for it: it is the host's, which no leg
--- has promised.
local function test_an_absent_path_skips_the_module_and_keeps_no_verdict(tmp: string)
  local root = project(tmp)
  module(root, "prog", outside(tmp) .. "/absent", 'error("a module with an absent requirement must not load")\n')
  for _, extra in ipairs({ {}, {}, { COSMIC_SANDBOX = "must" }, { COSMIC_CI_REQUIRE_SANDBOX = "1" } }) do
    local out, code = run(root, extra)
    assert(code == 0, out)
    assert(out:find("test: SKIP  prog_test test_passes: requires path:" .. outside(tmp) .. "/absent: ", 1, true), out)
    assert(out:find("test: SKIP  prog_test test_passes_too: requires path:", 1, true), out)
    assert(out:find("2 tests, 1 module; 2 ran, 0 stood, 2 skipped ", 1, true), out)
    assert(not out:find("must not load", 1, true), out)
  end
end

--- A requirement the platform never has makes the module not applicable:
--- counted apart from skipped, listed `N/A`, kept as no verdict, and no run
--- fails for it. COSMIC_TEST_PLATFORM=other makes the platform one with no
--- portable artifact and none of Linux's requirements, which no host is.
local function test_a_requirement_the_platform_lacks_is_not_applicable(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/artifact_test.tl", [[
local Test = require("cosmic.test")
Test.policy { requires = { "portable" } }
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
    assert(out:find("test: N/A  artifact_test test_a: requires portable: portable: this platform has none\n", 1, true), out)
    assert(out:find("test: N/A  artifact_test test_b: requires portable: ", 1, true), out)
    -- The module that applies runs once and then stands (a held run is keyed
    -- apart, and runs); the other has no verdict to stand on.
    if i <= 2 then
      assert(out:find("3 tests, 2 modules; " .. (i == 1 and "1 ran, 0 stood" or "0 ran, 1 stood") .. ", ",
        1, true), out)
    end
    assert(out:find(", 2 n/a (this platform has none of what they check), ", 1, true), out)
    assert(not out:find("skipped", 1, true) and not out:find("must not load", 1, true), out)
  end
end

--- A probe that cannot tell (a file the run may not read) fails the modules
--- that name it, saying why, and the rest of the run goes on.
local function test_a_probe_that_raises_fails_its_modules_alone(tmp: string)
  if sys.getuid() == 0 then return end -- root reads any file: nothing to refuse
  local root = project(tmp)
  local file = outside(tmp) .. "/closed"
  assert(Fs.write(file, "x\n"))
  assert(Fs.chmod(file, 0))
  module(root, "closed", file)
  assert(Fs.write(root .. "/plain_test.tl", "local function test_c() assert(true) end\n"))
  local out, code = run(root)
  assert(code ~= 0, out)
  assert(out:find("FAIL  closed_test test_passes: ", 1, true) and
      out:find("the probe of what it requires of the host failed: host_requires: ", 1, true), out)
  assert(out:find("2 of 3 failed", 1, true), out)
  assert(not out:find("FAIL  plain_test", 1, true), out)
end

--- A name the table does not have, or a Linux-class one, fails the build,
--- naming the rule, and nothing runs.
local function test_an_unknown_or_linux_requirement_fails_the_build(tmp: string)
  local root = project(tmp)
  for _, case in ipairs({ { "sandbxo", "unknown requirement \"sandbxo\"" },
      { "nest", "\"nest\" is a Linux-class requirement" } }) do
    assert(Fs.write(root .. "/typo_test.tl", 'local Test = require("cosmic.test")\n' ..
        'Test.policy { requires = { "' .. case[1] .. '" } }\nlocal function test_a() assert(true) end\n'))
    local out, code = run(root)
    assert(code ~= 0, out)
    assert(out:find(case[2], 1, true), out)
    assert(not out:find("test: PASS", 1, true), out)
  end
end

--- A `path:` the worker is given no host grant of fails the build too.
local function test_a_path_the_worker_could_not_see_fails_the_build(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/ungranted_test.tl", [[
local Test = require("cosmic.test")
Test.policy { requires = { "path:/etc/hostname" } }
local function test_a() assert(true) end
]]))
  local out, code = run(root)
  assert(code ~= 0, out)
  assert(out:find("needs a host grant of the path", 1, true), out)
end
