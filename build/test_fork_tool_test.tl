--- A module's tests run in copies of one worker ([`build.test_worker`]'s `--fork`): each still fails by itself,
--- starts with a directory of its own and the module as it loaded, and shows its own output.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local fixture = require("build.test_isolation_fixture")

Test.policy{
  profiles = { "cosmic", "proc" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
  env = { "COSMIC_SANDBOX", "COSMIC_TEST_SANDBOX" },
  requires = { "sandbox" },
  timeout = 120,
}

--- A project of one module whose tests, in order, pass, find what the one before left, end their process, fail,
--- print and hang; and of one whose load leaves a file open.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/many_test.tl", [[
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

Fs.put(Fs.stdout, "loading\n")
local ran = 0

-- Fails where an earlier test of the module left its mark: in the module, in its directory or beside it.
local function fresh(tmp: string)
  assert(ran == 0, "an earlier test's change to the module is seen")
  ran = ran + 1
  assert(Fs.exists(tmp .. "/mark") == false, "its directory holds what an earlier test left")
  assert(Fs.exists("/tmp/stray") == false, "what an earlier test left in /tmp is seen")
  assert(assert(sys.stat(tmp)).mtime ~= 12345, "the time an earlier test gave its directory is seen")
  assert(Fs.write(tmp .. "/mark", "left behind"))
  assert(sys.utimensat(tmp, 12345, 0, 12345, 0))
end

local function test_a_first()
  Fs.put(Fs.stdout, "first speaks\n")
  assert(true)
end
local function test_b_second(tmp: string)
  fresh(tmp)
end
local function test_c_third(tmp: string)
  fresh(tmp)
end
local function test_d_exits(tmp: string)
  fresh(tmp)
  Fs.put(Fs.stdout, "exiting\n")
  Proc.exit(0)
end
local function test_e_after_an_exit(tmp: string)
  fresh(tmp)
end
local function test_f_fails(tmp: string)
  fresh(tmp)
  assert(1 + 1 == 3, "arithmetic held")
end
local function test_g_after_a_failure(tmp: string)
  fresh(tmp)
  Fs.put(Fs.stdout, "seventh speaks\n")
end
local function test_h_litters(tmp: string)
  fresh(tmp)
  assert(Fs.write("/tmp/stray", "outside its directory"))
end
local function test_i_after_litter(tmp: string)
  fresh(tmp)
end
local function test_j_hangs(tmp: string)
  fresh(tmp)
  Fs.put(Fs.stdout, "about to hang\n")
  while true do end
end
local function test_k_after_a_hang(tmp: string)
  fresh(tmp)
end
]]))
  assert(Fs.write(root .. "/suite/open_test.tl", [[
local sys = require("cosmic.sys")
local held = assert(sys.open("/dev/null", sys.O_RDONLY))
local function test_a_reads()
  assert(sys.read(held, 1) == "")
end
local function test_b_reads()
  assert(sys.read(held, 1) == "")
end
]]))
  return root
end

--- Each test of a forked module has its own verdict, a directory nothing was left in, the module as it loaded and
--- its own output; a module whose load leaves a descriptor open runs a worker for each test.
local function test_a_modules_tests_run_in_copies_and_fail_alone(tmp: string)
  local root = project(tmp)
  local output = tmp .. "/run.out"
  local env = fixture.environment()
  env["TMPDIR"] = tmp .. "/temp"
  env["COSMIC_TEST_SANDBOX"] = ""
  assert(Fs.mkdirs(tmp .. "/temp"))
  local result = fixture.invoke(root, output, { "--timeout", "3", "--jobs", "1", "--show-output" }, env)
  local text = assert(Fs.read(output))
  if text:find("; sandboxed", 1, true) == nil then
    Test.skip("its run's workers ran unsandboxed, where none forks: this host nests no sandbox in this test's")
  end
  -- Only a kernel whose Landlock scopes no signal is a host that cannot check this: any other reason a worker gives
  -- for not forking for this module is a failure of what is tested.
  local refused = text:match("since none could fork %(suite%.many_test: ([^\n]*)")
  if refused ~= nil and refused:find("Landlock", 1, true) ~= nil then
    Test.skip("its run's workers could not fork here: " .. refused)
  end
  assert(refused == nil, "its workers did not fork for suite.many_test: " .. tostring(refused))
  assert(not result.ok, text)
  assert(text:find("suite.many_test test_d_exits: the test process exited with status 0 before it reported", 1, true),
    text)
  assert(text:find("suite.many_test test_f_fails: ", 1, true), text)
  assert(text:find("arithmetic held", 1, true), text)
  assert(text:find("suite.many_test test_j_hangs: timed out after 3 s", 1, true), text)
  assert(text:find("3 of 13 tests failed", 1, true), text)
  -- The tests after each failure ran, in a worker that followed the one that retired, as did the one after a test
  -- that wrote outside its directory.
  for _, name in ipairs({ "test_e_after_an_exit", "test_g_after_a_failure", "test_i_after_litter",
      "test_k_after_a_hang" }) do
    assert(text:find("suite.many_test " .. name .. ":", 1, true) == nil, name .. " failed:\n" .. text)
  end
  -- What the load printed is shown with each test that printed, and a test's output under it alone.
  local first = assert(text:match("PASS  suite%.many_test test_a_first\n(.-)\ntest: "), text)
  assert(first:find("loading", 1, true), first)
  assert(first:find("first speaks", 1, true), first)
  assert(first:find("seventh speaks", 1, true) == nil, first)
  local seventh = assert(text:match("PASS  suite%.many_test test_g_after_a_failure\n(.-)\ntest: "), text)
  assert(seventh:find("seventh speaks", 1, true), seventh)
  assert(seventh:find("first speaks", 1, true) == nil, seventh)
  -- What the hung test printed before its worker was ended is shown with its failure.
  local hung = assert(text:match("FAIL  suite%.many_test test_j_hangs: timed out.-\n(.-)\ntest: "), text)
  assert(hung:find("  | about to hang", 1, true), hung)
  -- The tests shared workers: more ran in copies than there were workers. Nine of the module's eleven have a
  -- result from a copy: not the one its worker was ended under, nor the one left after it, which a worker of its
  -- own ran.
  local copies, workers = text:match("forks: (%d+) tests ran in copies of (%d+) workers")
  assert(copies == "9", text)
  assert((tonumber(workers) or 99) < 9, text)
  assert(text:find("1 module ran a worker for each test, since none could fork (suite.open_test: ", 1, true), text)
end

--- A bailing run starts no test after the first failure, in a worker that shares its module's tests too: the tests
--- after the one that failed are counted as not run, and none of them has a verdict.
local function test_a_bailing_run_starts_no_copy_after_a_failure(tmp: string)
  local root = project(tmp)
  local output = tmp .. "/run.out"
  local env = fixture.environment()
  env["TMPDIR"] = tmp .. "/temp"
  env["COSMIC_TEST_SANDBOX"] = ""
  assert(Fs.mkdirs(tmp .. "/temp"))
  local result = fixture.invoke(root, output, { "--timeout", "3", "--jobs", "1", "--bail", "suite/many_test.tl" },
    env)
  local text = assert(Fs.read(output))
  if text:find("; sandboxed", 1, true) == nil then
    Test.skip("its run's workers ran unsandboxed, where none forks: this host nests no sandbox in this test's")
  end
  assert(not result.ok, text)
  assert(text:find("suite.many_test test_d_exits: the test process exited with status 0 before it reported", 1, true),
    text)
  assert(text:find("suite.many_test test_f_fails", 1, true) == nil, text)
  assert(text:find("1 of 4 tests failed", 1, true), text)
  assert(text:find("7 not run after the first failure", 1, true), text)
end

--- A module whose worker's scratch directory is the host's (it declares a directory to read) shares workers too:
--- each test finds its directory empty, and a failing test's is kept as that test left it.
local function test_a_host_directory_is_put_back_and_a_failing_tests_is_kept(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/host_test.tl", [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.policy { grants = { { path = "suite", letters = "r" } } }

local function fresh(tmp: string, mark: string)
  assert(Fs.exists(tmp .. "/mark") == false, "its directory holds what an earlier test left")
  assert(Fs.write(tmp .. "/mark", mark))
  local opened = assert(sys.open("/dev/null", sys.O_RDONLY))
  Fs.put(Fs.stdout, "opened " .. tostring(opened) .. "\n")
  assert(sys.close(opened))
end

local function test_a_first(tmp: string)
  fresh(tmp, "the first")
end
local function test_b_second(tmp: string)
  fresh(tmp, "the second")
end
local function test_c_fails(tmp: string)
  fresh(tmp, "the failing one")
  assert(1 + 1 == 3, "arithmetic held")
end
local function test_d_after_a_failure(tmp: string)
  fresh(tmp, "the last")
end
]]))
  local output = tmp .. "/run.out"
  local env = fixture.environment()
  env["TMPDIR"] = tmp .. "/temp"
  env["COSMIC_TEST_SANDBOX"] = ""
  assert(Fs.mkdirs(tmp .. "/temp"))
  local result = fixture.invoke(root, output, { "--timeout", "30", "--jobs", "1", "--show-output" }, env)
  local text = assert(Fs.read(output))
  if text:find("; sandboxed", 1, true) == nil then
    Test.skip("its run's workers ran unsandboxed, where none forks: this host nests no sandbox in this test's")
  end
  local refused = text:match("since none could fork %(suite%.host_test: ([^\n]*)")
  if refused ~= nil and refused:find("Landlock", 1, true) ~= nil then
    Test.skip("its run's workers could not fork here: " .. refused)
  end
  assert(refused == nil, "its workers did not fork for suite.host_test: " .. tostring(refused))
  assert(not result.ok, text)
  assert(text:find("1 of 4 tests failed", 1, true), text)
  assert(text:find("suite.host_test test_c_fails: ", 1, true), text)
  -- The test after the failing one is the only one left, so a worker of its own runs it.
  assert(text:find("forks: 3 tests ran in copies of 1 worker", 1, true), text)
  local kept = assert(text:match("its directory is kept: ([^\n]*)"), text)
  assert(Fs.read(kept .. "/mark") == "the failing one", kept)
  -- The directories of the tests that passed are gone, with the workers that ran them.
  local marks = 0
  for _, path in ipairs((assert(Fs.walk(tmp .. "/temp")))) do
    if path:sub(-5) == "/mark" then marks = marks + 1 end
  end
  assert(marks == 1, "the run left " .. tostring(marks) .. " of its tests' files:\n" .. text)
  -- The first descriptor a test opens has one number, in a copy as in the worker of its own the last test had.
  local numbers: mut {string:boolean} = {}
  local shown = 0
  for number in text:gmatch("opened (%d+)") do
    numbers[number] = true
    shown = shown + 1
  end
  local distinct = 0
  for _ in pairs(numbers) do distinct = distinct + 1 end
  assert(shown == 4 and distinct == 1, text)
end

--- A test its worker saw pass and the runner failed (it made no call to `assert`, in a held run) keeps its
--- directory too: the worker empties none before the runner has passed its test.
local function test_a_test_the_runner_fails_keeps_its_directory(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/held_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy { grants = { { path = "suite", letters = "r" } } }

local function test_a_asserts_nothing(tmp: string)
  local _, _ = Fs.write(tmp .. "/mark", "unchecked")
end
local function test_b_second(tmp: string)
  assert(Fs.exists(tmp .. "/mark") == false, "its directory holds what an earlier test left")
end
local function test_c_third(tmp: string)
  assert(Fs.exists(tmp .. "/mark") == false, "its directory holds what an earlier test left")
end
]]))
  local output = tmp .. "/run.out"
  local env = fixture.environment()
  env["TMPDIR"] = tmp .. "/temp"
  env["COSMIC_TEST_SANDBOX"] = "1"
  assert(Fs.mkdirs(tmp .. "/temp"))
  local result = fixture.invoke(root, output, { "--timeout", "30", "--jobs", "1" }, env)
  local text = assert(Fs.read(output))
  if text:find("; sandboxed", 1, true) == nil then
    Test.skip("its run's workers ran unsandboxed, where none forks: this host nests no sandbox in this test's")
  end
  local refused = text:match("since none could fork %(suite%.held_test: ([^\n]*)")
  if refused ~= nil and refused:find("Landlock", 1, true) ~= nil then
    Test.skip("its run's workers could not fork here: " .. refused)
  end
  assert(refused == nil, "its workers did not fork for suite.held_test: " .. tostring(refused))
  assert(not result.ok, text)
  assert(text:find("suite.held_test test_a_asserts_nothing: made no call to assert", 1, true), text)
  assert(text:find("1 of 3 tests failed", 1, true), text)
  assert(text:find("the runner failed its test", 1, true), text)
  local kept = assert(text:match("its directory is kept: ([^\n]*)"), text)
  assert(Fs.read(kept .. "/mark") == "unchecked", kept)
end

--- A module's tests share workers in a run of more modules than may run at once, and have a worker each, so that
--- they run beside each other, in a run of no more modules than that.
local function test_a_small_modules_tests_share_a_worker_only_in_a_crowded_run(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  for _, name in ipairs({ "one", "two", "three" }) do
    assert(Fs.write(root .. "/suite/" .. name .. "_test.tl", [[
local function test_a_first()
  assert(true)
end
local function test_b_second()
  assert(true)
end
]]))
  end
  local env = fixture.environment()
  env["TMPDIR"] = tmp .. "/temp"
  env["COSMIC_TEST_SANDBOX"] = ""
  assert(Fs.mkdirs(tmp .. "/temp"))
  local crowded_output = tmp .. "/crowded.out"
  local crowded = fixture.invoke(root, crowded_output, { "--all", "--jobs", "2" }, env)
  local text = assert(Fs.read(crowded_output))
  if text:find("; sandboxed", 1, true) == nil then
    Test.skip("its run's workers ran unsandboxed, where none forks: this host nests no sandbox in this test's")
  end
  local refused = text:match("since none could fork %(suite%.[a-z]+_test: ([^\n]*)")
  if refused ~= nil and refused:find("Landlock", 1, true) ~= nil then
    Test.skip("its run's workers could not fork here: " .. refused)
  end
  assert(crowded.ok, text)
  assert(text:find("forks: 6 tests ran in copies of 3 workers", 1, true), text)
  local few_output = tmp .. "/few.out"
  local few = fixture.invoke(root, few_output,
    { "--all", "--jobs", "2", "suite/one_test.tl", "suite/two_test.tl" }, env)
  local few_text = assert(Fs.read(few_output))
  assert(few.ok, few_text)
  assert(few_text:find("4 tests passed", 1, true), few_text)
  assert(few_text:find("forks:", 1, true) == nil, few_text)
end
