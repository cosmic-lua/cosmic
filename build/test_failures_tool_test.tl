--- A failure a run records stays in `failures` after a later run of its
--- test passes, under the key it failed under: a flake keeps the key of
--- its pass, and a fixed test does not.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local this_program = require("build.this_program")
local support = require("build.test_support_fixture")

Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
}

local function test_a_flake_keeps_its_failure_and_a_fix_its_other_key(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local root, flag, answer = tmp .. "/project", tmp .. "/flag", tmp .. "/answer"
  assert(Fs.mkdirs(root))
  assert(Fs.write(flag, "unchanged\n"))
  assert(Fs.set_mtime(flag, 1600000000))
  assert(Fs.write(answer, "fail\n"))
  -- Keys hold contents, never times: the flag's mtime changes no key, the
  -- `answer` file's contents change the key of the module that reads it.
  -- Each test has a module of its own, as a key is of a module's declared
  -- inputs.
  assert(Fs.write(root .. "/flaky_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
Test.policy { grants = { { path = "]] .. flag .. [[", letters = "r" } } }
local function test_flaky()
  assert(assert(Fs.stat("]] .. flag .. [[")).mtime == 1700000000, "flaked on purpose")
end
]]))
  assert(Fs.write(root .. "/fixed_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
Test.policy { grants = { { path = "]] .. answer .. [[", letters = "r" } } }
local function test_fixed()
  assert(assert(Fs.read("]] .. answer .. [[")) == "pass\n", "not fixed yet")
end
]]))
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["COSMIC_SANDBOX"] = nil
  env["COSMIC_TEST_ALL"] = nil
  env["COSMIC_VERDICT_CACHE"] = tmp .. "/cache/verdicts.db"
  local function run(name: string, passes: boolean)
    local output = tmp .. "/" .. name .. ".out"
    local fd = assert(Fs.open_write(output))
    local start = this_program.program({ "test", "--jobs", "1" },
      { timeout_ns = Child.FOREVER, cwd = root, env = env, stdout = fd, stderr = fd })
    local result = assert(Child.run(start.argv, start.options))
    assert(Fs.close(fd))
    assert(result.ok == passes, assert(Fs.read(output)))
  end
  run("failed", false)
  assert(Fs.set_mtime(flag, 1700000000))
  assert(Fs.write(answer, "pass\n"))
  run("passed", true)
  local db = assert(Sqlite.open(support.build_dir(root) .. "/build.db"))
  local failed = assert(db:rows("SELECT f.test, f.message FROM failures f " ..
      "JOIN runs r USING (path, test) WHERE r.passed = 1 ORDER BY f.test"))
  local flaked = assert(db:rows("SELECT f.test FROM failures f " ..
      "JOIN runs r USING (path, test) WHERE r.passed = 1 AND f.key = r.key"))
  assert(db:close())
  assert(#failed == 2, "failures after a pass: " .. tostring(#failed))
  local fixed, flaky = assert(failed[1]), assert(failed[2])
  assert(fixed:text(1) == "test_fixed" and fixed:text(2):find("not fixed yet", 1, true) ~= nil, fixed:text(2))
  assert(flaky:text(1) == "test_flaky" and flaky:text(2):find("flaked on purpose", 1, true) ~= nil, flaky:text(2))
  assert(#flaked == 1 and assert(flaked[1]):text(1) == "test_flaky", "flakes: " .. tostring(#flaked))
end
