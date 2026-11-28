--- End to end: a `bench_*` function of a test file is a test in a plain `cosmic test`, called once, and
--- `cosmic test --bench` times it and prints its line, or its JSON object with `--json`. Each run here is
--- unsandboxed (COSMIC_TEST_SANDBOX=0), so it means the same on every host.

local Fake = require("cosmic.fake")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local TestSandboxFixture = require("build.test_sandbox_fixture")
local Test = require("cosmic.test")
-- Required, so the fake's main is of each test's closure.
local _ = require("build.test_against_fake")

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

local function test_each_timed_batch_is_handed_an_empty_directory(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/files_test.tl", [[
local Bench = require("cosmic.bench")
local Fs = require("cosmic.fs")

local function bench_writes_one_file(b: Bench.B)
  assert(#assert(Fs.list(b.dir)) == 0, "the last batch's file is still in " .. b.dir)
  assert(Fs.write(b.dir .. "/one", "x"))
  b.reset()
  for _ = 1, b.n do local _ = assert(Fs.read(b.dir .. "/one")) end
end
]]))
  local out, code = run(root, { "--bench", "files_test.tl", "--rounds", "2", "--target-ms", "1" })
  assert(code == 0, out)
  assert(out:find("files_test.tl:bench_writes_one_file ", 1, true), out)
end

--- An old cosmic that times `tally_test.tl:bench_sum` at a second an operation ([`build.test_against_fake`]).
local function old_cosmic(tmp: string): string
  local path = tmp .. "/old-cosmic"
  assert(Fake.place(assert(Fake.build(tmp .. "/fake", "build.test_against_fake")), path))
  return path
end

local function test_against_compares_each_bench_on_two_binaries(tmp: string)
  local root = project(tmp)
  local out, code = run(root, { "--bench", "--against", old_cosmic(tmp), "--rounds", "6", "--target-ms", "1",
    "tally_test.tl" })
  assert(code == 0, out)
  assert(out:find("best of 6", 1, true), out)
  local line = assert(out:match("\n(tally_test%.tl:bench_sum [^\n]*)"), out)
  assert(line:find(" 1000000000 ", 1, true) and line:sub(-6) == "faster", line)
end

local function test_against_with_json_prints_one_comparison_per_bench(tmp: string)
  local root = project(tmp)
  local old = old_cosmic(tmp)
  local out, code = run(root, { "--bench", "--json", "--against", old, "--rounds", "6", "--target-ms", "1" })
  assert(code == 0, out)
  local value = assert(Json.decode_object((assert(out:match('({"[^\n]*})'), out))))
  assert(value["name"] == "tally_test.tl:bench_sum" and value["rounds"] == 6 and value["verdict"] == "faster", out)
  local binary = Json.string_of(Json.object_of(value["old"])!["binary"])!
  assert(binary:sub(-11) == "/old-cosmic", out)
end

local function test_against_refuses_too_few_rounds_and_a_binary_alone(tmp: string)
  local root = project(tmp)
  local old = old_cosmic(tmp)
  local out, code = run(root, { "--bench", "--against", old, "--rounds", "5" })
  assert(code == 2, out)
  assert(out:find("at least 6 rounds", 1, true), out)
  out, code = run(root, { "--bench", "--binary", old })
  assert(code == 2, out)
  assert(out:find("--binary names the new side of --against", 1, true), out)
  out, code = run(root, { "--against", old })
  assert(code == 2, out)
  assert(out:find("--against is an option of a bench run", 1, true), out)
  out, code = run(root, { "--bench", "--against", tmp .. "/absent" })
  assert(code == 2, out)
  assert(out:find("--against " .. tmp .. "/absent", 1, true), out)
end

local function test_against_copies_what_a_bench_requires_and_the_testdata_it_names(tmp: string)
  local root = project(tmp)
  assert(Fs.mkdirs(root .. "/testdata/words"))
  assert(Fs.write(root .. "/testdata/words/one.txt", "one"))
  assert(Fs.write(root .. "/helper.tl", "local record helper\n  word: string\nend\nhelper.word = 'one'\nreturn helper\n"))
  -- The bench is tally_test.tl's, which the fake times; its body raises unless both reached the copy.
  assert(Fs.write(root .. "/tally_test.tl", [[
local Bench = require("cosmic.bench")
local Fs = require("cosmic.fs")
local helper = require("helper")

local function bench_sum(b: Bench.B)
  assert(Fs.read("testdata/words/one.txt")! == helper.word)
  b.reset()
  for _ = 1, b.n do local _ = helper.word end
end
]]))
  local out, code = run(root, { "--bench", "--against", old_cosmic(tmp), "--rounds", "6", "--target-ms", "1",
    "tally_test.tl" })
  assert(code == 0, out)
  assert(out:find("tally_test.tl:bench_sum ", 1, true), out)
end
