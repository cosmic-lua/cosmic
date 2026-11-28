--- End to end: a `fuzz_*` function of a test file returns a [`Fuzz.Target`] that a plain `cosmic test` checks at
--- a few inputs, and `cosmic test --fuzz-deep` at many. Each run here is unsandboxed (COSMIC_TEST_SANDBOX=0), so it
--- means the same on every host.

local Fs = require("cosmic.fs")
local TestSandboxFixture = require("build.test_sandbox_fixture")
local Test = require("cosmic.test")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A property that holds for its first 100 inputs and fails after: a plain run's 64 pass, a deep run's many fail it,
--- so a run's verdict says how many inputs it drew.
local COUNTED = [[
local Fuzz = require("cosmic.fuzz")

local function test_adds()
  assert(1 + 1 == 2)
end

local function fuzz_counts(): Fuzz.Target
  local checked = 0
  return Fuzz.target({
    name = "counts",
    gen = function(src: Fuzz.Source): string return tostring(src:int(0, 9)) end,
    check = function(_: string): (boolean, string)
      checked = checked + 1
      return checked <= 100, "input " .. tostring(checked) .. " is past the 100 a plain run draws"
    end,
  })
end
]]

--- A project of one module whose test file holds a test and a fuzz property, and one module with only a test.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/tally_test.tl", COUNTED))
  assert(Fs.write(root .. "/plain_test.tl", "local function test_plain()\n  assert(true)\nend\n"))
  return root
end

local function run(root: string, args?: {string}, env?: {string:string}): string, integer?
  local ran = TestSandboxFixture.unsandboxed(root, env or {}, args)
  return ran.text, ran.code
end

local function test_a_plain_run_checks_a_fuzz_property_as_a_test(tmp: string)
  local root = project(tmp)
  local out, code = run(root)
  assert(code == 0, out)
  assert(out:find("3 tests", 1, true), out)
end

local function test_a_deep_run_checks_only_the_fuzz_properties_at_many_inputs(tmp: string)
  local root = project(tmp)
  local out, code = run(root, { "--fuzz-deep" })
  assert(code ~= 0, out)
  assert(out:find("is past the 100", 1, true), out)
  assert(not out:find("test_adds", 1, true) and not out:find("test_plain", 1, true), out)
end

local function test_a_deep_run_draws_the_inputs_the_environment_says(tmp: string)
  local root = project(tmp)
  local out, code = run(root, { "--fuzz-deep" }, { FUZZ_ITERS = "80" })
  assert(code == 0, out)
  assert(out:find("1 test", 1, true) and not out:find("3 tests", 1, true), out)
end

local function test_a_fuzz_function_that_returns_no_target_fails(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/wrong_test.tl", "local function fuzz_wrong(): integer\n  return 1\nend\n"))
  local out, code = run(root)
  assert(code ~= 0, out)
  assert(out:find("a fuzz_* function returns a Fuzz.Target", 1, true), out)
end

local function test_a_deep_run_of_a_module_with_no_fuzz_property_is_refused(tmp: string)
  local root = project(tmp)
  local out, code = run(root, { "--fuzz-deep", "plain_test.tl" })
  assert(code ~= 0, out)
  assert(out:find("--fuzz-deep: no fuzz property in", 1, true), out)
end

local function test_a_deep_run_is_no_bench_run(tmp: string)
  local root = project(tmp)
  local out, code = run(root, { "--fuzz-deep", "--bench" })
  assert(code == 2, out)
  assert(out:find("--fuzz-deep and --bench are runs of their own", 1, true), out)
end
