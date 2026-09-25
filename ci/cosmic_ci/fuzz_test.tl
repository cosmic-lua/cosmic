local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Fuzz = require("cosmic_ci.fuzz")
local Predicate = require("cosmic_ci.fs_predicate")
local Proc = require("cosmic.proc")

local function write(path: string, data: string, mode?: integer)
  assert(Fs.mkdirs(Fs.dirname(path)))
  assert(Fs.write(path, data, mode))
end

local function read(path: string): string return (assert(Fs.read(path))) end

local function test_discover_prunes_top_level_trees_and_sorts(tmp: string)
  for _, path in ipairs({ "b/z_fuzz_test.tl", "a/y_fuzz_test.tl",
      "a/b/x_fuzz_test.tl", "o/p_fuzz_test.tl", "vendor/v_fuzz_test.tl",
      "ci/c_fuzz_test.tl", "a/plain_test.tl", "a/fuzz_test.tl",
      "a/_fuzz_test.tl", "deep/o/kept_fuzz_test.tl" }) do
    write(tmp .. "/" .. path, "")
  end
  local found = table.concat(Fuzz.discover(tmp), " ")
  assert(found == "./a/_fuzz_test.tl ./a/b/x_fuzz_test.tl ./a/y_fuzz_test.tl" ..
    " ./b/z_fuzz_test.tl ./deep/o/kept_fuzz_test.tl", found)
end

local function test_header_names_the_seed_and_iterations()
  assert(Fuzz.header("42", "2000") == "FUZZ_SEED=42 FUZZ_ITERS=2000\n\n" ..
    "A failure's report names the FUZZ_CASE that checks its input again," ..
    " and its iteration under this seed.\n")
end

local function test_failure_lists_failing_tests_then_reports()
  local output = "build: PASS\ntest: PASS a\ntest: FAIL b\nreport one\n" ..
    "test: FAIL c\n\n" .. string.rep("x", 400) .. "\nlast"
  local text = Fuzz.failure(output, "7")
  assert(text == "\nThe shrunk inputs are the run's fuzz-inputs-7 artifact;" ..
    " once fixed, keep each in testdata/fuzz/<property>/ as its report says." ..
    "\n\n~~~~\ntest: FAIL b\ntest: FAIL c\n\nreport one\n\n" ..
    string.rep("x", 300) .. "\nlast\n~~~~\n", text)
end

local function test_failure_bounds_what_it_lists()
  local parts: {string} = {}
  for i = 1, 40 do parts[#parts + 1] = "test: FAIL " .. tostring(i) .. "\n" end
  for i = 1, 70 do parts[#parts + 1] = "report " .. tostring(i) .. "\n" end
  local text = Fuzz.failure(table.concat(parts), "1")
  assert(text:find("test: FAIL 30\n\n", 1, true) and
    not text:find("test: FAIL 31", 1, true), "failing lines were not bounded")
  assert(text:find("report 60\n~~~~\n", 1, true) and
    not text:find("report 61", 1, true), "report lines were not bounded")
end

local function test_cancelled_summary_shows_the_end_of_the_output()
  local head = "\nCancelled, at the time limit or by hand, before fuzzing" ..
    " finished: a property\nthat hangs is the likeliest cause. The end of" ..
    " its output:\n\n~~~~\n"
  assert(Fuzz.cancelled_summary(nil) == head .. "~~~~\n")
  local parts: {string} = {}
  for i = 1, 50 do parts[#parts + 1] = "line " .. tostring(i) end
  parts[#parts + 1] = string.rep("y", 500)
  local text = Fuzz.cancelled_summary(table.concat(parts, "\n"))
  assert(text:sub(1, #head) == head)
  assert(text:find("~~~~\nline 12\n", 1, true) and
    not text:find("line 11\n", 1, true), "the tail was not 40 lines")
  assert(text:sub(-(300 + 6)) == string.rep("y", 300) .. "\n~~~~\n",
    "the last line was not cut")
end

--- A checkout whose checked core is a script standing in for it: it
--- says what it was given and ran with, and fails as told.
local function fake_checkout(root: string, exit: string)
  write(root .. "/AGENTS.md", "fixture\n")
  write(root .. "/build/a_fuzz_test.tl", "")
  write(root .. "/build/fuzz/b_fuzz_test.tl", "")
  write(root .. "/ci/c_fuzz_test.tl", "")
  write(root .. "/o/sanitized/bin/cosmic", table.concat({
    "#!/bin/sh",
    "echo \"args: $*\"",
    "echo \"env: $FUZZ_SEED $FUZZ_ITERS $COSMIC_AUTO_BOOT $COSMIC_TEST_TIMEOUT $TMPDIR\"",
    "echo \"cwd: $(pwd)\"",
    "echo 'build: PASS'",
    "echo 'test: FAIL ./build/a_fuzz_test.tl' >&2",
    "echo 'the report'",
    "exit " .. exit,
  }, "\n") .. "\n", 0x1ed)
end

local function test_execute_runs_the_checked_core_on_every_property(tmp: string)
  local root, temp = tmp .. "/checkout", tmp .. "/runner-temp"
  fake_checkout(root, "3")
  assert(Fs.mkdirs(temp))
  local log_fd = assert(Fs.open_write(tmp .. "/log"))
  local summary: {string} = {}
  local status = Fuzz.execute({ root = root, temp = temp,
    env = { FUZZ_SEED = "9", FUZZ_ITERS = "5", PATH = "/usr/bin:/bin" },
    log = log_fd,
    summarize = function(text: string) summary[#summary + 1] = text end })
  assert(Fs.close(log_fd))
  assert(status == 3, tostring(status))
  local out = read(temp .. "/fuzz.out")
  assert(out == read(tmp .. "/log"), "the log differs from the kept output")
  assert(out:find("args: test --all ./build/a_fuzz_test.tl" ..
    " ./build/fuzz/b_fuzz_test.tl\n", 1, true), out)
  assert(out:find("env: 9 5 0 1200 " .. temp .. "/fuzz\n", 1, true), out)
  assert(out:find("cwd: " .. assert(Fs.absolute(root)) .. "\n", 1, true), out)
  local exists = Predicate.is_dir(temp .. "/fuzz")
  assert(exists, "the scratch directory was not made")
  assert(read(temp .. "/fuzz.status") == "3\n")
  assert(#summary == 2 and summary[1] == Fuzz.header("9", "5") and
    summary[2] == Fuzz.failure(out, "9"), table.concat(summary))
  assert(summary[2]:find("~~~~\ntest: FAIL ./build/a_fuzz_test.tl\n\n", 1, true))
end

local function test_execute_passes_and_says_so_briefly(tmp: string)
  local root, temp = tmp .. "/checkout", tmp .. "/runner-temp"
  fake_checkout(root, "0")
  assert(Fs.mkdirs(temp))
  local log_fd = assert(Fs.open_write(tmp .. "/log"))
  local summary: {string} = {}
  local status = Fuzz.execute({ root = root, temp = temp, env = {},
    log = log_fd,
    summarize = function(text: string) summary[#summary + 1] = text end })
  assert(Fs.close(log_fd))
  assert(status == 0 and read(temp .. "/fuzz.status") == "0\n")
  assert(#summary == 1 and summary[1] == Fuzz.header("", ""))
end

local function test_execute_reports_a_core_that_cannot_start(tmp: string)
  local root, temp = tmp .. "/checkout", tmp .. "/runner-temp"
  write(root .. "/AGENTS.md", "fixture\n")
  assert(Fs.mkdirs(temp))
  local log_fd = assert(Fs.open_write(tmp .. "/log"))
  local status = Fuzz.execute({ root = root, temp = temp, env = {},
    log = log_fd, summarize = function(_text: string) end })
  assert(Fs.close(log_fd))
  assert(status == 127 and read(temp .. "/fuzz.status") == "127\n")
  assert(read(temp .. "/fuzz.out"):find("o/sanitized/bin/cosmic: ", 1, true))
end

--- The driver's commands read their context from the environment: the
--- driver runs in a project of its own, as orchestration_test's do.
local function test_driver_commands_read_the_environment(tmp: string)
  local here = assert(Fs.absolute("."))
  local project = tmp .. "/driver-project"
  assert(Fs.mkdirs(project))
  assert(assert(Child.run({ "/bin/cp", "-R", here .. "/cosmic_ci", project })).ok)
  local root, temp = tmp .. "/checkout", tmp .. "/runner-temp"
  fake_checkout(root, "1")
  assert(Fs.mkdirs(temp))
  local summary = tmp .. "/summary.md"
  -- The job's own GITHUB_* and RUNNER_TEMP, under CI, are replaced.
  local env = Env.all()
  env.GITHUB_WORKSPACE, env.RUNNER_TEMP = root, temp
  env.GITHUB_STEP_SUMMARY = summary
  env.FUZZ_SEED, env.FUZZ_ITERS = "11", "2"
  local driver = { assert(Proc.executable()), project .. "/cosmic_ci/driver.tl" }
  local fuzz = assert(Child.run({ driver[1], driver[2], "fuzz" },
    { cwd = project, env = env, stdout = "capture", stderr = "capture" }))
  assert(fuzz.code == 1, (fuzz.stdout or "") .. (fuzz.stderr or ""))
  assert((fuzz.stdout or ""):find("env: 11 2 0 1200 ", 1, true), fuzz.stdout)
  local text = read(summary)
  assert(text:sub(1, #Fuzz.header("11", "2")) == Fuzz.header("11", "2"))
  assert(text:find("fuzz-inputs-11 artifact", 1, true), text)
  local cancelled = assert(Child.run({ driver[1], driver[2], "fuzz-cancelled" },
    { cwd = project, env = env, stdout = "capture", stderr = "capture" }))
  assert(cancelled.ok, (cancelled.stdout or "") .. (cancelled.stderr or ""))
  assert(read(summary) == text ..
    Fuzz.cancelled_summary(read(temp .. "/fuzz.out")))
  assert(Fs.remove(temp .. "/fuzz.out"))
  assert(assert(Child.run({ driver[1], driver[2], "fuzz-cancelled" },
    { cwd = project, env = env, stdout = "null", stderr = "null" })).ok,
    "fuzz-cancelled refused a run that kept no output")
end
