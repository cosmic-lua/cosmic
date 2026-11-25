--- [`Test.mode`] says whether the run checks types as the code runs
--- (`cosmic test --check-types`), in the worker that runs the test.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its test starts. A test that runs `cosmic test`
--- takes minutes where the host is loaded.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  timeout = 180,
}

--- Runs `cosmic test` with `words` on a project whose one test fails
--- where the run checks types, and returns what it said.
local function invoke(tmp: string, name: string, words: {string}): string
  local root = tmp .. "/" .. name
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/mode_test.tl", [[
local Test = require("cosmic.test")

local function test_the_mode_is_plain()
  assert(not Test.mode().types_checked, "the run checks types")
end
]]))
  local output = tmp .. "/" .. name .. ".out"
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["COSMIC_VERDICT_CACHE"] = "0"
  env["COSMIC_TEST_ALL"] = nil
  env["COSMIC_TEST_CHECK_TYPES"] = nil
  env["TMPDIR"] = tmp
  local argv: mut {string} = { "test" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local started = this_program.program(argv, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(150),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  assert(result ~= nil, trouble)
  return (assert(Fs.read(output)))
end

local function test_a_test_knows_whether_the_run_checks_types(tmp: string)
  local plain = invoke(tmp, "plain", {})
  assert(plain:find("1 test passed", 1, true), plain)
  local checked = invoke(tmp, "checked", { "--check-types" })
  assert(checked:find("FAIL  suite.mode_test test_the_mode_is_plain", 1, true), checked)
  assert(checked:find("the run checks types", 1, true), checked)
end
