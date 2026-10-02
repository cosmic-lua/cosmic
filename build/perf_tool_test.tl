--- Exercise the measurement fixture lifecycle; elapsed times are ignored and
--- thirty pairs are always exploratory, never performance acceptance evidence.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The complete tool builds private fixtures; their portable launchers need
--- the system shell. The standalone controller is the declared source file.
Test.needs{ tool = true, system = true, reads = { "build/perf.tl" } }

local function run(tmp: string, source: string): Child.Result
  local script = tmp .. "/controller.tl"
  assert(Fs.write(script, source))
  local binary = assert(Proc.executable())
  local started = this_program.program({ "--standalone", script, binary, binary, tmp .. "/results", "30", "uses" },
    { cwd = tmp, stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) })
  return (assert(Child.run(started.argv, started.options)))
end

local function test_independent_fixture_histories_match_through_warmups_and_samples(tmp: string)
  local result = run(tmp, (assert(Fs.read("build/perf.tl"))))
  assert(result.code == 2, (result.stderr or "") .. (result.stdout or ""))
  local metadata = assert(Json.decode_object((assert(Fs.read(tmp .. "/results/metadata.json")))))
  assert(metadata.protocol == "fixed-sample-v3" and metadata.exploratory == true)
  local root = assert(Fs.absolute(tmp .. "/results"))
  local names = { "aa-a", "aa-b", "ab-a", "ab-b" }
  local manifest = metadata.fixtures as {{string:any}}
  assert(#manifest == 4)
  for i, name in ipairs(names) do assert(manifest[i].id == name and manifest[i].root == root .. "/" .. name) end
  for _, phase in ipairs({ "aa", "ab" }) do
    local observations = assert(Json.decode((assert(Fs.read(tmp .. "/results/" .. phase .. "-a/o/perf/" .. phase .. "-uses.json"))))) as {{string:any}}
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
  local source = assert(Fs.read("build/perf.tl"))
  local changed, count = source:gsub("local samples = run_pairs%(parent,", "parent = a\n    local samples = run_pairs(parent,")
  assert(count == 1)
  local result = run(tmp, changed)
  assert(not result.ok and (result.stderr or ""):find("unbalanced fixture build history", 1, true),
    (result.stderr or "") .. (result.stdout or ""))
end
