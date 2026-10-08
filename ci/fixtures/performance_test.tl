--- Exercise the measurement fixture lifecycle; elapsed times are ignored and
--- thirty pairs are always exploratory, never performance acceptance evidence.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Fixture = require("cosmic_ci.fixture")
local Test = require("cosmic.test")

--- The selected candidate, including its carried modules, and the controller
--- source are both inputs. The CI driver is only the outer test supervisor;
--- each candidate runs the controller and private fixtures itself.
Test.policy{
  grants = {
    { path = "testdata/ci-fixtures/performance/program", letters = "r" },
    { path = "testdata/ci-fixtures/performance/perf.tl", letters = "r" },
  },
  profiles = { "system" },
}

local function controller(): string
  return (assert(Fs.read(Fixture.placed("performance") .. "/perf.tl")))
end

-- Four real timestamp-settlement waits add eight seconds of setup. The
-- checked core also executes 132 sampled commands; keep its child deadline
-- below the driver's 60-second per-test bound so diagnostics can be checked.
local controller_timeout_ns <const> = Clock.seconds(45)

local function diagnostic(result: Child.Result): string
  return string.format("performance controller: code=%s signal=%s timed_out=%s\n%s%s",
    tostring(result.code), tostring(result.signal), tostring(result.timed_out),
    result.stderr or "", result.stdout or "")
end

local function run(tmp: string, source: string): Child.Result
  local script = tmp .. "/controller.tl"
  assert(Fs.write(script, source))
  local binary = Fixture.placed("performance") .. "/program"
  -- The sandbox exposes the shared core cache read-only; this candidate may
  -- carry a core the CI driver has never extracted.
  local env = Fixture.environment({ COSMIC_PORTABLE_CACHE = tmp .. "/cores" })
  return (assert(Child.run({ binary, "--standalone", script, binary, binary, tmp .. "/results", "30", "uses" },
    { cwd = tmp, env = env, stdout = "capture", stderr = "capture", timeout_ns = controller_timeout_ns })))
end

local function generated(root: string, tmp: string): string
  local binary = Fixture.placed("performance") .. "/program"
  local env = Fixture.environment({ COSMIC_TREE = root,
    COSMIC_BUILD_HOME = Fs.dirname(root) .. "/build-home", COSMIC_PORTABLE_CACHE = tmp .. "/cores" })
  local result = assert(Child.run({ binary, "-e",
    "print(require('build.paths').required(assert(require('cosmic.env').get('COSMIC_TREE'))))" },
    { env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(result.ok, diagnostic(result))
  return (assert((result.stdout or ""):match("^([^\n]+)\n$"), "candidate named no generated directory"))
end

local function test_independent_fixture_histories_match_through_warmups_and_samples(tmp: string)
  local result = run(tmp, controller())
  assert(result.code == 2, diagnostic(result))
  local metadata = assert(Json.decode_object((assert(Fs.read(tmp .. "/results/metadata.json")))))
  assert(metadata.protocol == "fixed-sample-v3" and metadata.exploratory == true)
  local root = assert(Fs.absolute(tmp .. "/results"))
  local names = { "aa-a", "aa-b", "ab-a", "ab-b" }
  local manifest = metadata.fixtures as {{string:any}}
  assert(#manifest == 4)
  for i, name in ipairs(names) do
    assert(manifest[i].id == name and manifest[i].root == root .. "/" .. name)
  end
  for _, phase in ipairs({ "aa", "ab" }) do
    local output = generated(root .. "/" .. phase .. "-a", tmp)
    local observations = assert(Json.decode((assert(Fs.read(output .. "/perf/" .. phase .. "-uses.json"))))) as {{string:any}}
    assert(#observations == 66)
    for i, observation in ipairs(observations) do
      local iteration = (i + 1) // 2
      local before, after = observation.before as {string}, observation.after as {string}
      assert(#before == 6 and #after == 6)
      assert(before[5] == tostring(3 + iteration) and before[6] == before[5])
      assert(after[5] == tostring(4 + iteration) and after[6] == after[5])
      assert(after[1] == "0" and after[2] == "6" and after[3] == "0")
      assert(observation.cwd == root .. "/" .. phase .. "-" .. (i % 2 == 1 and "a" or "b"))
    end
  end
end

local function test_old_shared_parent_alias_is_rejected(tmp: string)
  local source = controller()
  local changed, count = source:gsub("local samples = run_pairs%(parent,", "parent = a\n    local samples = run_pairs(parent,")
  assert(count == 1)
  local result = run(tmp, changed)
  assert(not result.ok and (result.stderr or ""):find("unbalanced fixture build history", 1, true),
    diagnostic(result))
end
