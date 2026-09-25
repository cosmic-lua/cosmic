local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Fuzz = require("cosmic_ci.fuzz")
local Predicate = require("cosmic_ci.fs_predicate")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")

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

--- A function answering `text` `size` bytes at a time, then "".
local function pieces(text: string, size: integer): function(): string
  local at = 1
  return function(): string
    local piece = text:sub(at, at + size - 1)
    at = at + size
    return piece
  end
end

--- What the shell scripts' pipelines made of `output`, run on it.
local function shell(tmp: string, output: string, script: string): string
  write(tmp .. "/shell.out", output)
  local env = Env.all()
  env.LC_ALL, env.OUT = "C", tmp .. "/shell.out"
  local ran = assert(Child.run({ "/bin/sh", "-c", script },
    { env = env, stdout = "capture", stderr = "capture" }))
  assert(ran.ok, ran.stderr)
  return ran.stdout or ""
end

local failure_script <const> = table.concat({
  "grep '^test: FAIL' \"$OUT\" | cut -c1-300 | head -30 || true",
  "echo",
  "grep -v -e '^build:' -e '^test: ' \"$OUT\" | cut -c1-300 | head -60 || true",
}, "\n")

local tail_script <const> =
  "tail -n 40 \"$OUT\" 2>/dev/null | cut -c1-300 || true"

--- Outputs where a line's length, its end, or a chunk's edge counts.
local function outputs(): {string}
  local many: {string} = {}
  for i = 1, 40 do many[#many + 1] = "test: FAIL " .. tostring(i) .. "\n" end
  for i = 1, 70 do many[#many + 1] = "report " .. tostring(i) .. "\n" end
  local wide: {string} = {}
  for i = 1, 45 do wide[#wide + 1] = tostring(i) .. string.rep("w", 70000) end
  return {
    "", "\n", "\n\n", "a", "a\n", "a\n\nb", "\nb",
    "build: PASS\ntest: PASS a\ntest: FAIL b\nreport one\n" ..
      "test: FAIL c\n\n" .. string.rep("x", 400) .. "\nlast",
    table.concat(many),
    string.rep("y", 200000) .. "\n" .. string.rep("short\n", 45),
    table.concat(wide, "\n"),
    table.concat(wide, "\n") .. "\n",
  }
end

local function test_failure_matches_the_shell_it_replaced(tmp: string)
  local prefix = "\nThe shrunk inputs are the run's fuzz-inputs-7 artifact;" ..
    " once fixed, keep each in testdata/fuzz/<property>/ as its report says." ..
    "\n\n~~~~\n"
  for n, output in ipairs(outputs()) do
    local expected = prefix .. shell(tmp, output, failure_script) .. "~~~~\n"
    for _, size in ipairs({ 1, 7, 65536 }) do
      if size > 1 or #output < 10000 then
        local text = Fuzz.failure(pieces(output, size), "7")
        assert(text == expected, "output " .. tostring(n) .. " in pieces of " ..
          tostring(size) .. " differs:\n" .. text .. "\nfrom:\n" .. expected)
      end
    end
  end
end

local function test_failure_bounds_what_it_lists()
  local parts: {string} = {}
  for i = 1, 40 do parts[#parts + 1] = "test: FAIL " .. tostring(i) .. "\n" end
  for i = 1, 70 do parts[#parts + 1] = "report " .. tostring(i) .. "\n" end
  local text = Fuzz.failure(pieces(table.concat(parts), 5), "1")
  assert(text:find("test: FAIL 30\n\n", 1, true) and
    not text:find("test: FAIL 31", 1, true), "failing lines were not bounded")
  assert(text:find("report 60\n~~~~\n", 1, true) and
    not text:find("report 61", 1, true), "report lines were not bounded")
end

local function test_failure_stops_reading_once_it_has_its_lines()
  local read_after = false
  local served = 0
  local lines = string.rep("test: FAIL x\n", 30) .. string.rep("report\n", 60)
  local text = Fuzz.failure(function(): string
    served = served + 1
    if served == 1 then return lines end
    read_after = true
    return ""
  end, "1")
  assert(not read_after, "it read past the lines it keeps")
  assert(select(2, text:gsub("report\n", "")) == 60)
end

local function test_tail_matches_the_shell_it_replaced(tmp: string)
  assert(Fuzz.tail(tmp .. "/missing") == nil)
  for n, output in ipairs(outputs()) do
    write(tmp .. "/fuzz.out", output)
    local tail = assert(Fuzz.tail(tmp .. "/fuzz.out"))
    local got = table.concat(tail, "\n") .. (#tail > 0 and "\n" or "")
    local expected = shell(tmp, output, tail_script)
    assert(got == expected, "output " .. tostring(n) .. "'s tail differs:\n" ..
      got .. "\nfrom:\n" .. expected)
  end
end

local function test_cancelled_summary_shows_the_end_of_the_output()
  local head = "\nCancelled, at the time limit or by hand, before fuzzing" ..
    " finished: a property\nthat hangs is the likeliest cause. The end of" ..
    " its output:\n\n~~~~\n"
  assert(Fuzz.cancelled_summary(nil) == head .. "~~~~\n")
  assert(Fuzz.cancelled_summary({ "a", "", "b" }) == head .. "a\n\nb\n~~~~\n")
end

--- A checkout whose checked core is a script standing in for it: it
--- says what it was given and ran with, and fails as told.
local function fake_checkout(root: string, exit: string, body?: {string})
  write(root .. "/AGENTS.md", "fixture\n")
  write(root .. "/build/a_fuzz_test.tl", "")
  write(root .. "/build/fuzz/b_fuzz_test.tl", "")
  write(root .. "/ci/c_fuzz_test.tl", "")
  write(root .. "/o/sanitized/bin/cosmic", table.concat(body or {
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
    summary[2] == Fuzz.failure(pieces(out, 65536), "9"), table.concat(summary))
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

local function test_execute_reports_a_core_it_cannot_execute(tmp: string)
  local root, temp = tmp .. "/checkout", tmp .. "/runner-temp"
  fake_checkout(root, "0")
  assert(Fs.chmod(root .. "/o/sanitized/bin/cosmic", 0x1a4))
  assert(Fs.mkdirs(temp))
  local log_fd = assert(Fs.open_write(tmp .. "/log"))
  local status = Fuzz.execute({ root = root, temp = temp, env = {},
    log = log_fd, summarize = function(_text: string) end })
  assert(Fs.close(log_fd))
  assert(status == 126 and read(temp .. "/fuzz.status") == "126\n",
    tostring(status))
end

--- The driver's commands read their context from the environment: the
--- driver runs in a project of its own, as orchestration_test's do.
local function driver_project(tmp: string): {string}, string
  local here = assert(Fs.absolute("."))
  local project = tmp .. "/driver-project"
  assert(Fs.mkdirs(project))
  assert(assert(Child.run({ "/bin/cp", "-R", here .. "/cosmic_ci", project })).ok)
  return { assert(Proc.executable()), project .. "/cosmic_ci/driver.tl" }, project
end

local function test_driver_commands_read_the_environment(tmp: string)
  local driver, project = driver_project(tmp)
  local root, temp = tmp .. "/checkout", tmp .. "/runner-temp"
  fake_checkout(root, "1")
  assert(Fs.mkdirs(temp))
  local summary = tmp .. "/summary.md"
  -- The job's own GITHUB_* and RUNNER_TEMP, under CI, are replaced.
  local env = Env.all()
  env.GITHUB_WORKSPACE, env.RUNNER_TEMP = root, temp
  env.GITHUB_STEP_SUMMARY = summary
  env.FUZZ_SEED, env.FUZZ_ITERS = "11", "2"
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
    Fuzz.cancelled_summary(Fuzz.tail(temp .. "/fuzz.out")))
  assert(Fs.remove(temp .. "/fuzz.out"))
  assert(assert(Child.run({ driver[1], driver[2], "fuzz-cancelled" },
    { cwd = project, env = env, stdout = "null", stderr = "null" })).ok,
    "fuzz-cancelled refused a run that kept no output")
end

--- Waits up to `seconds` for the file at `path` to hold `text`.
local function until_found(path: string, text: string, seconds: integer): boolean
  local deadline = Time.monotonic_ns() + seconds * 1000000000
  while Time.monotonic_ns() < deadline do
    local held = Fs.read(path) or ""
    if held:find(text, 1, true) then return true end
    Time.sleep_ns(20 * 1000 * 1000)
  end
  return false
end

--- `driver.tl fuzz` started on a checkout whose core runs `body`, its
--- stdout (the job's log) in `<tmp>/log`.
local function start_fuzz(tmp: string, body: {string},
    extra?: {string:string}): Child.Handle, string, string
  local driver, project = driver_project(tmp)
  local root, temp = tmp .. "/checkout", tmp .. "/runner-temp"
  fake_checkout(root, "0", body)
  assert(Fs.mkdirs(temp))
  local env = Env.all()
  env.GITHUB_WORKSPACE, env.RUNNER_TEMP = root, temp
  env.GITHUB_STEP_SUMMARY = tmp .. "/summary.md"
  if extra then for name, value in pairs(extra) do env[name] = value end end
  local log_fd = assert(Fs.open_write(tmp .. "/log"))
  local handle, trouble = Child.start({ driver[1], driver[2], "fuzz" },
    { cwd = project, env = env, stdout = log_fd, stderr = "null" })
  assert(Fs.close(log_fd))
  assert(handle, trouble)
  return handle, temp, tmp .. "/log"
end

--- A SIGTERM the driver gets reaches the core, whose status is kept
--- before the driver dies of the signal itself.
local function test_fuzz_passes_a_signal_on_and_keeps_the_status(tmp: string)
  local handle <close>, temp, log = start_fuzz(tmp, {
    "#!/bin/sh",
    "trap 'echo trapped; exit 143' TERM",
    "echo ready",
    "i=0",
    "while [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done",
    "exit 9",
  })
  assert(until_found(temp .. "/fuzz.out", "ready\n", 120),
    "the core did not start")
  assert(handle:stop(sys.SIGTERM))
  local result = assert(handle:wait(30000))
  assert(result.signal == sys.SIGTERM,
    "the driver ended with " .. tostring(result.code) .. "/" .. tostring(result.signal))
  assert(read(temp .. "/fuzz.status") == "143\n", read(temp .. "/fuzz.status"))
  assert(read(temp .. "/fuzz.out"):find("trapped\n", 1, true), "the trap did not run")
  assert(read(log):find("trapped\n", 1, true), "the log missed the trap's line")
end

--- The log gets the core's output while the core runs: this core goes
--- on only once the test has seen its first line there.
local function test_fuzz_streams_the_log_as_the_core_runs(tmp: string)
  local go = tmp .. "/go"
  local handle <close>, temp, log = start_fuzz(tmp, {
    "#!/bin/sh",
    "echo first",
    "i=0",
    "while [ ! -e \"$FUZZ_TEST_GO\" ]; do",
    "  [ $i -lt 400 ] || exit 9",
    "  sleep 0.05; i=$((i+1))",
    "done",
    "echo second",
  }, { FUZZ_TEST_GO = go })
  -- The core's own output first, which waits out the driver's build;
  -- then the log, well within the time the core waits.
  local started = until_found(temp .. "/fuzz.out", "first\n", 120)
  local seen = started and until_found(log, "first\n", 5)
  -- Let the core go on either way, so nothing is left running.
  write(go, "")
  local result = assert(handle:wait(30000))
  assert(seen, "the log did not get the core's first line while it ran")
  assert(result.code == 0, tostring(result.code) .. "/" .. tostring(result.signal))
  assert(read(temp .. "/fuzz.status") == "0\n")
  assert(read(log):find("first\nsecond\n", 1, true), read(log))
end
