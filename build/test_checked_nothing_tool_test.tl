--- End to end: a test that passes having made no call to `assert`
--- checked nothing. The `cosmic test` that ran it lists it and counts it
--- in the summary and keeps no verdict of it; a held run fails it. Each
--- run here is unsandboxed (COSMIC_TEST_SANDBOX=0), so it means the same on
--- every host.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A project of one test module: a test that asserts nothing, ones that
--- assert directly, through a helper and through a copy of `assert` taken as
--- the module loads, and one that skips.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/checks_test.tl", [[
local Test = require("cosmic.test")

local check = assert

local function same(a: integer, b: integer)
  assert(a == b, "differ")
end

local function test_asserts_nothing()
  local _ = 1 + 1
end

local function test_asserts_directly()
  assert(1 + 1 == 2)
end

local function test_asserts_in_a_helper()
  same(2, 1 + 1)
end

local function test_asserts_through_a_captured_assert()
  check(1 + 1 == 2)
end

local function test_skips()
  Test.skip("this host cannot")
end
]]))
  return root
end

--- What `cosmic test` in `root` printed and its status, run
--- unsandboxed with `extra` set in its environment, and held to
--- sandboxing by nothing else.
local function run(root: string, extra: {string:string}): string, integer
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  env.COSMIC_SANDBOX = nil
  env.COSMIC_CI_REQUIRE_SANDBOX = nil
  for name, value in pairs(extra) do env[name] = value end
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60),
  })
  local result = assert(Child.run(started.argv, started.options))
  return (result.stdout or "") .. (result.stderr or ""), result.code
end

local function test_a_pass_that_asserted_nothing_is_listed_not_failed_and_runs_every_time(tmp: string)
  local root = project(tmp)
  local out, code = run(root, {})
  assert(code == 0, out)
  -- Only that test: not the ones that asserted, nor the one that skipped.
  assert(out:find("test: CHECKED NOTHING  checks_test test_asserts_nothing\n", 1, true), out)
  local _, listed = out:gsub("CHECKED NOTHING", "")
  assert(listed == 1, out)
  assert(out:find("1 skipped (this host could not check it), 1 passed checking nothing (no assert ran), ", 1, true), out)
  -- No verdict is kept of it or of the skip: both run again, the others stand.
  out, code = run(root, {})
  assert(code == 0, out)
  assert(out:find("; 2 ran, 3 stood, ", 1, true), out)
  assert(out:find("test: CHECKED NOTHING  checks_test test_asserts_nothing\n", 1, true), out)
end

local function test_a_held_run_fails_a_pass_that_asserted_nothing(tmp: string)
  for i, held in ipairs({ { COSMIC_SANDBOX = "must" }, { COSMIC_CI_REQUIRE_SANDBOX = "1" } }) do
    local out, code = run(project(tmp .. "/" .. tostring(i)), held)
    assert(code ~= 0, out)
    assert(out:find("checks_test test_asserts_nothing: passed checking nothing: it made no call to assert", 1, true), out)
    assert(out:find("1 of 5 failed", 1, true), out)
  end
end

local function test_a_test_that_fails_is_a_failure_not_a_pass_that_checked_nothing(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/raises_test.tl", [[
local function test_raises()
  error("raised")
end
]]))
  local out, code = run(root, {})
  assert(code ~= 0, out)
  assert(out:find("raises_test test_raises: ", 1, true), out)
  assert(not out:find("raises_test test_raises: passed checking nothing", 1, true), out)
  local _, listed = out:gsub("CHECKED NOTHING", "")
  assert(listed == 1, out)
end
