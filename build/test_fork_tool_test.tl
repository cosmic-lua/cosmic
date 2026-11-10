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
