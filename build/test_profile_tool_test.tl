--- `cosmic test --profile <dir>` runs the tests it selects, whatever verdict stands, and each worker writes its
--- profile into the directory, which `cosmic profile` reads.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

--- The program itself, which its tests start. A test that runs `cosmic test` takes minutes where the host is
--- loaded.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  timeout = 120,
}

--- A project of one module whose test spends its time in a function of its own.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/spin_test.tl", [[
local function spin(n: integer): integer
  local s = 0
  for i = 1, n do s = s + i end
  return s
end

local function test_spins()
  local total = 0
  for _ = 1, 300 do total = total + spin(100000) end
  assert(total > 0)
end
]]))
  return root
end

--- Runs `cosmic <words>` in `root`, unsandboxed whatever this run's switch, and returns its exit code and what it
--- said.
local function invoke(root: string, output: string, words: {string}): (integer, string)
  local fd = assert(Fs.open_write(output))
  local env = Test.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["COSMIC_VERDICT_CACHE"] = "0"
  env["COSMIC_TEST_ALL"] = nil
  env["COSMIC_PROFILE_HZ"] = "2000"
  env["TMPDIR"] = Fs.dirname(output)
  local started = Test.cosmic(words, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(100),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  assert(result ~= nil, trouble)
  return result.code or -1, (assert(Fs.read(output)))
end

--- A test that stands runs again with `--profile`, and its worker's profile names the test's own function.
local function test_profile_runs_each_test_and_writes_its_worker_profile(tmp: string)
  local root = project(tmp)
  local first_code, first = invoke(root, tmp .. "/first.out", { "test" })
  assert(first_code == 0, first)
  local code, said = invoke(root, tmp .. "/profiled.out", { "test", "--profile", tmp .. "/prof" })
  assert(code == 0, said)
  assert(said:find("1 ran, 0 stood", 1, true) ~= nil, said)
  local names = assert(Fs.list(tmp .. "/prof"))
  assert(#names >= 1, "no profile was written")
  local report_code, report = invoke(root, tmp .. "/report.out", { "profile", "--by", "function", tmp .. "/prof" })
  assert(report_code == 0, report)
  assert(report:find("spin@suite.spin_test:1\n", 1, true) ~= nil, report)
end

local function test_profile_needs_a_directory(tmp: string)
  local root = project(tmp)
  local code, said = invoke(root, tmp .. "/empty.out", { "test", "--profile", "" })
  assert(code == 2 and said:find("test: --profile needs a directory", 1, true) ~= nil, said)
end
