--- `cosmic test --min PCT` and `--min-file PCT` fail a whole run whose
--- line coverage, overall or in one file, is under the floor. The child
--- project has one module with a function no test calls, so it is partly
--- covered, and one test module that is covered whole.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  timeout = 180,
}

local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/lib.tl", [[
local record lib end

function lib.used(x: integer): integer
  return x + 1
end

function lib.unused(x: integer): integer
  local y = x * 2
  local z = y + 1
  return z
end

return lib
]]))
  assert(Fs.write(root .. "/lib_test.tl", [[
local lib = require("lib")

local function test_used()
  assert(lib.used(1) == 2)
end
]]))
  return root
end

--- Runs `cosmic test` with `words` in `root`, unsandboxed whatever this
--- run's switch, and answers its status and what it said.
local function invoke(root: string, output: string, words: {string}): Child.Result, string
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["COSMIC_VERDICT_CACHE"] = "0"
  env["COSMIC_TEST_ALL"] = nil
  env["TMPDIR"] = Fs.dirname(output)
  local argv: mut {string} = { "test" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local started = this_program.program(argv, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(100),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  assert(result ~= nil, trouble)
  return result, (assert(Fs.read(output)))
end

--- The percentage of the run's `test: coverage` line, as a number.
local function covered(text: string): number
  local percent = text:match("test: coverage (%d+%.%d)%% %(%d+/%d+ lines")
  assert(percent ~= nil, text)
  return assert(tonumber(percent))
end

--- The percentage a floor failure prints for the run's coverage line: rounded
--- down, so that it never reads as reaching a floor it is under.
local function under_figure(text: string): string
  local hit, total = text:match("test: coverage %d+%.%d%% %((%d+)/(%d+) lines")
  assert(hit ~= nil and total ~= nil, text)
  return string.format("%.1f", (assert(math.tointeger(tonumber(hit))) * 1000 // assert(math.tointeger(tonumber(total)))) / 10)
end

--- With neither flag the run reports its coverage and passes. A total floor
--- above the coverage fails the run as a test failure (status 1, not the 4
--- of a tree that does not compile), and its summary names the shortfall;
--- one at or below it passes.
local function test_a_total_floor_above_the_coverage_fails_the_run(tmp: string)
  local root = project(tmp)
  local plain, said = invoke(root, tmp .. "/plain.out", {})
  assert(plain.ok, said)
  local percent = covered(said)
  assert(percent > 0 and percent < 100, said)
  assert(said:find("informational, never a failure", 1, true), said)

  local met, met_text = invoke(root, tmp .. "/met.out", { "--min", "1" })
  assert(met.ok, met_text)
  assert(not met_text:find("never a failure", 1, true), met_text)
  assert(not met_text:find("floor not met", 1, true), met_text)

  local short, text = invoke(root, tmp .. "/short.out", { "--min", "100" })
  assert(not short.ok and short.code == 1, tostring(short.code) .. text)
  assert(text:find("test: FAIL  coverage: " .. under_figure(said) .. "% (", 1, true), text)
  assert(text:find("is under --min 100%", 1, true), text)
  local summary = text:match("[^\n]*\n$") or ""
  assert(summary:find("1 test passed", 1, true) and
      summary:find("coverage floor not met: " .. under_figure(said) .. "% under --min 100%", 1, true),
    summary)
  assert(not text:find("--min-file", 1, true), text)
end

--- A floor per file names each file under it, with its percentage, and no
--- file above it. The partly covered module is under 80, the test module
--- that is covered whole is not.
local function test_a_file_floor_names_each_file_under_it(tmp: string)
  local root = project(tmp)
  local short, text = invoke(root, tmp .. "/file.out", { "--min-file", "80" })
  assert(not short.ok and short.code == 1, tostring(short.code) .. text)
  assert(text:match("test: FAIL  coverage: lib %d+%.%d%% %(%d+/%d+ lines%) is under %-%-min%-file 80%%"), text)
  assert(not text:find("coverage: lib_test", 1, true), text)
  assert(not text:find("is under --min ", 1, true), text)
  local summary = text:match("[^\n]*\n$") or ""
  assert(summary:find("coverage floor not met: 1 file under --min-file 80%", 1, true), summary)

  local met, met_text = invoke(root, tmp .. "/met.out", { "--min-file", "10", "--min", "10" })
  assert(met.ok, met_text)
end

--- A run that stands entirely on verdicts has the lines those verdicts hit
--- when they ran, so a floor holds for it as for the run that earned them.
local function test_a_run_that_stands_on_verdicts_still_has_coverage_to_compare(tmp: string)
  local root = project(tmp)
  local first, first_text = invoke(root, tmp .. "/first.out", {})
  assert(first.ok and first_text:find("1 ran, 0 stood", 1, true) ~= nil, first_text)
  local percent = covered(first_text)
  local said = first_text

  local stood, stood_text = invoke(root, tmp .. "/stood.out", { "--min", "1", "--min-file", "10" })
  assert(stood.ok and stood_text:find("0 ran, 1 stood", 1, true) ~= nil, stood_text)
  assert(covered(stood_text) == percent, stood_text)

  local short, text = invoke(root, tmp .. "/short.out", { "--min", "100" })
  assert(not short.ok and short.code == 1, tostring(short.code) .. text)
  assert(text:find("0 ran, 1 stood", 1, true), text)
  assert(text:find("coverage floor not met: " .. under_figure(said) .. "% under --min 100%", 1, true), text)
end

--- A floor is over the whole tree, so a run of chosen tests or one share
--- of the tests is refused before it builds, as a usage error.
local function test_a_floor_needs_a_whole_run(tmp: string)
  local root = project(tmp)
  for _, words in ipairs({ { "--min", "1", "lib_test.tl" }, { "--min-file", "1", "--shard", "1/2" } }) do
    local refused, text = invoke(root, tmp .. "/refused.out", words)
    assert(not refused.ok and refused.code == 2, tostring(refused.code) .. text)
    assert(text:find("--min and --min-file need a whole run", 1, true), text)
  end
end

--- A value that is no percentage is a usage error that names the flag.
local function test_a_floor_that_is_no_percentage_is_refused(tmp: string)
  local root = project(tmp)
  local refused, text = invoke(root, tmp .. "/refused.out", { "--min", "101" })
  assert(not refused.ok and refused.code == 2, tostring(refused.code) .. text)
  assert(text:find("test: --min must be a percentage from 0 to 100, not 101", 1, true), text)
end

--- `--min=PCT` is `--min PCT`.
local function test_a_floor_may_be_given_with_an_equals_sign(tmp: string)
  local root = project(tmp)
  local short, text = invoke(root, tmp .. "/short.out", { "--min=100" })
  assert(not short.ok and short.code == 1 and text:find("is under --min 100%", 1, true) ~= nil, text)
  local met, met_text = invoke(root, tmp .. "/met.out", { "--min=1", "--min-file=1" })
  assert(met.ok, met_text)
end

--- A per-file floor holds a run that stands entirely on verdicts too.
local function test_a_file_floor_holds_a_run_that_stood(tmp: string)
  local root = project(tmp)
  local first = invoke(root, tmp .. "/first.out", {})
  assert(first.ok)
  local short, text = invoke(root, tmp .. "/short.out", { "--min-file", "80" })
  assert(not short.ok and short.code == 1, text)
  assert(text:find("0 ran, 1 stood", 1, true) ~= nil, text)
  assert(text:match("test: FAIL  coverage: lib %d+%.%d%% %(%d+/%d+ lines%) is under %-%-min%-file 80%%") ~= nil, text)
end

--- A failing test and a floor not met both show: the failed summary carries
--- the clause and the status is 1.
local function test_a_failing_test_and_a_floor_both_show(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/bad_test.tl", "local function test_bad()\n  error(\"boom\")\nend\n"))
  local short, text = invoke(root, tmp .. "/short.out", { "--min", "100" })
  assert(not short.ok and short.code == 1, text)
  assert(text:find("test: FAIL  bad_test test_bad", 1, true) ~= nil, text)
  assert(text:find("is under --min 100%", 1, true) ~= nil, text)
  local summary = text:match("[^\n]*\n$") or ""
  assert(summary:find("1 of 2 tests failed", 1, true) ~= nil and
      summary:find("; coverage floor not met: ", 1, true) ~= nil, summary)
end

--- A run that stopped early reached only part of the lines, so it judges no
--- floor and says so; the failure that stopped it is the run's.
local function test_a_bailed_run_judges_no_floor(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/a_test.tl", "local function test_a()\n  error(\"first\")\nend\n"))
  assert(Fs.write(root .. "/b_test.tl", "local function test_b()\n  assert(true)\nend\n"))
  local bailed, text = invoke(root, tmp .. "/bail.out", { "--jobs", "1", "--bail", "--min", "100" })
  assert(not bailed.ok and bailed.code == 1, text)
  assert(text:find("test: coverage floor not judged: the run did not finish", 1, true) ~= nil, text)
  assert(text:find("is under --min", 1, true) == nil, text)
  assert(text:find("coverage floor not met", 1, true) == nil, text)
end

--- A tree with no line to cover is under no floor, so a floor holds
--- vacuously and says so.
local function test_a_tree_with_no_lines_meets_any_floor(tmp: string)
  local root = tmp .. "/empty"
  assert(Fs.mkdirs(root))
  local met, text = invoke(root, tmp .. "/empty.out", { "--min", "90", "--min-file", "90" })
  assert(met.ok, text)
  assert(text:find("(0/0 lines; no lines to cover, so a floor holds vacuously)", 1, true) ~= nil, text)
  assert(text:find("is under", 1, true) == nil, text)
end
