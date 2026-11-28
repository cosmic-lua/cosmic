--- Benches of cosmic's own tooling, each a run of this program as a child, timed to its exit on a warm cache: `fix
--- --check` of one file, `test` of one module and `test --check-types` of it, in a project of one module of the
--- bench's own. Each measures the tool's fixed cost, not the cost of a large tree. Each run is unsandboxed
--- (COSMIC_TEST_SANDBOX=0), so it means the same on every host.

local Bench = require("cosmic.bench")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

--- The program itself, which its benches start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- Writes a project of one module and its test file to `dir`/project and returns its path.
local function project(dir: string): string
  local root = dir .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/tally.tl", [[
local record Tally
end

--- The sum of `a` and `b`.
function Tally.add(a: integer, b: integer): integer
  return a + b
end

return Tally
]]))
  assert(Fs.write(root .. "/tally_test.tl", [[
local Tally = require("tally")

local function test_adds()
  assert(Tally.add(1, 1) == 2)
end
]]))
  return root
end

--- Times this program run with `words` in a fresh project, after one warming run.
local function running(b: Bench.B, words: {string})
  local env = Test.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["COSMIC_SANDBOX"] = nil
  env["COSMIC_CI_REQUIRE_SANDBOX"] = nil
  local started = Test.cosmic(words, { cwd = project(b.dir), env = env, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(120) })
  local function run()
    local result = assert(Child.run(started.argv, started.options))
    assert(result.ok, table.concat(words, " ") .. ": " .. tostring(result.stdout) .. tostring(result.stderr))
  end
  run()
  b.reset()
  for _ = 1, b.n do run() end
end

local function bench_fix_check_one_file(b: Bench.B) running(b, { "fix", "--check", "tally.tl" }) end
local function bench_test_one_module(b: Bench.B) running(b, { "test", "tally_test.tl" }) end
local function bench_check_types_one_module(b: Bench.B)
  running(b, { "test", "--check-types", "tally_test.tl" })
end
