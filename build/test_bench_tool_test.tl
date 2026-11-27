--- End to end: a `bench_*` function of a test file is a test in a plain `cosmic test`, called once, and
--- `cosmic test --bench` times it and prints its line, or its JSON object with `--json`. Each run here is
--- unsandboxed (COSMIC_TEST_SANDBOX=0), so it means the same on every host.

local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local TestSandboxFixture = require("build.test_sandbox_fixture")
local Test = require("cosmic.test")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A project of one module whose test file holds a test and a bench, and one module with only a test.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/tally_test.tl", [[
local Bench = require("cosmic.bench")

local function test_adds()
  assert(1 + 1 == 2)
end

local function bench_sum(b: Bench.B)
  b.bytes = 8
  b.reset()
  local total = 0
  for i = 1, b.n do total = total + i end
end
]]))
  assert(Fs.write(root .. "/plain_test.tl", [[
local function test_plain()
  assert(true)
end
]]))
  return root
end

local function run(root: string, args?: {string}): string, integer?
  local ran = TestSandboxFixture.unsandboxed(root, {}, args)
  return ran.text, ran.code
end

local function test_a_plain_run_calls_a_bench_once_as_a_test(tmp: string)
  local root = project(tmp)
  local out, code = run(root)
  assert(code == 0, out)
  assert(not out:find("NO ASSERT", 1, true), out)
  assert(not out:find("ns/op", 1, true), out)
  assert(out:find("3 tests", 1, true), out)
end

local function test_a_bench_run_prints_each_bench_line_and_no_test(tmp: string)
  local root = project(tmp)
  local out, code = run(root, { "--bench", "--rounds", "2", "--target-ms", "1" })
  assert(code == 0, out)
  local _, lines = out:gsub("ns/op", "")
  assert(lines == 1, out)
  assert(out:find("tally_test.tl:bench_sum ", 1, true) and out:find(" GB/s", 1, true), out)
end

local function test_a_bench_run_with_json_prints_one_object_per_bench(tmp: string)
  local root = project(tmp)
  local out, code = run(root, { "--bench", "--json", "--rounds", "3", "--target-ms", "1" })
  assert(code == 0, out)
  local line = assert(out:match('({"[^\n]*})'), out)
  local value = assert(Json.decode_object(line))
  assert(value["name"] == "tally_test.tl:bench_sum" and value["rounds"] == 3 and value["bytes"] == 8, line)
end

local function test_a_bench_option_without_bench_is_refused(tmp: string)
  local root = project(tmp)
  for _, flag in ipairs({ { "--rounds", "2" }, { "--target-ms", "1" }, { "--json" } }) do
    local out, code = run(root, flag)
    assert(code == 2, out)
    assert(out:find(flag[1]! .. " is an option of a bench run", 1, true), out)
  end
end

local function test_a_bench_run_of_a_module_with_no_bench_is_refused(tmp: string)
  local root = project(tmp)
  local out, code = run(root, { "--bench", "plain_test.tl" })
  assert(code ~= 0, out)
  assert(out:find("--bench: no bench in", 1, true), out)
end

local function test_a_bench_that_raises_fails_the_plain_run(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/broken_test.tl", [[
local Bench = require("cosmic.bench")

local function bench_raises(b: Bench.B)
  b.reset()
  error("renamed away")
end
]]))
  local out, code = run(root)
  assert(code ~= 0, out)
  assert(out:find("broken_test bench_raises: ", 1, true) and out:find("renamed away", 1, true), out)
end
