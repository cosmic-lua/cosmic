--- Adversarial protocol tests exercise the public API in real processes.
--- reads: cosmic/fuzz/testdata
local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local fuzz = require("cosmic.fuzz")
local json = require("cosmic.json")
local proc = require("cosmic.proc")

local function scenario(name: string): {string: any}
  local root = check.must(fs.temp_dir(check.must(env.get("TEST_TMPDIR")) .. "/case-XXXXXX"))
  if name == "corpus" then
    check.must(fs.make_dirs(root .. "/corpus/corpus"))
    check.must(fs.write(root .. "/corpus/corpus/regression.input", "saved\0\255"))
  end
  local handle = check.must(child.start({check.must(proc.interpreter()),
        "cosmic/fuzz/testdata/protocol.lua"}, {env = env.list({
            drop = {"FUZZ_ISOLATE", "COSMIC_FUZZ_WORKER"},
            set = {FUZZ_CASE = name, FUZZ_ROOT = root},
          })}))
  local result = check.must(handle:wait(15000))
  check.truthy(result.ok, result.stderr)
  return check.must(json.decode_object(result.stdout))
end

local function test_pass_requires_worker_completion()
  local r = scenario("pass")
  check.equal(r.status, "pass")
  check.equal(r.generated, 8)
  local empty = scenario("zero_exit")
  check.equal(empty.status, "error", "exit zero without completion must fail")
end

local function test_exact_crashing_input_is_captured_not_regenerated()
  local r = scenario("crash")
  check.equal(r.status, "crash")
  check.equal(r.iteration, 5)
  check.equal(r.reproduction, "reproduced")
  local path = r.saved_input
  assert(path is string)
  check.equal(check.must(fs.read(path)), "5\0\255")
  local result_path = r.saved_result
  assert(result_path is string)
  local stored = check.must(fuzz.read_result(result_path))
  check.equal(stored.input, "5\0\255", "result file preserves arbitrary bytes")
  local corpus = fs.dirname(path) .. "/promoted"
  check.must(fuzz.promote(stored, corpus))
  local files = check.must(fs.glob(corpus .. "/crash", "*.input"))
  check.equal(#files, 1)
  check.equal(check.must(fs.read(files[1])), "5\0\255")
end

local function test_unreproduced_failure_remains_failed()
  local r = scenario("stateful")
  check.equal(r.status, "failure")
  check.equal(r.iteration, 5)
  check.equal(r.reproduction, "not_reproduced")
end

local function test_timeouts_are_killed_and_attributed()
  local r = scenario("timeout")
  check.equal(r.status, "timeout")
  check.equal(r.iteration, 1)
  check.equal(r.has_input, true)
  check.equal(r.reproduction, "reproduced")
end

local function test_ambient_selectors_cannot_skip_the_suite()
  check.equal(scenario("ambient").status, "error")
  check.equal(scenario("stale_worker").status, "error")
end

local function test_corpus_precedes_generation_and_replay_bypasses_it()
  local r = scenario("corpus")
  check.equal(r.status, "failure")
  check.equal(r.generated, 0)
  check.equal(r.reproduction, "reproduced")
  check.equal(scenario("replay").status, "pass")
end

local function test_shrinking_preserves_failure_category()
  local r = scenario("shrink")
  check.equal(r.status, "failure")
  check.equal(r.failure_kind, "assertion")
  local path = r.saved_input
  assert(path is string)
  check.truthy(#check.must(fs.read(path)) >= 4, "a looping candidate cannot replace an assertion")
  local interrupted = scenario("shrink_crash")
  check.equal(interrupted.status, "failure", "retain original assertion if shrink crashes")
end

local function test_generator_errors_have_no_invented_input()
  local r = scenario("generator_throw")
  check.equal(r.status, "error")
  check.equal(r.has_input, false)
  local crashed = scenario("generator_crash")
  check.equal(crashed.status, "crash")
  check.equal(crashed.phase, "generate")
  check.equal(crashed.has_input, false)
end

local function test_budget_and_throw_are_distinct()
  check.equal(scenario("budget").status, "timeout")
  local r = scenario("throw")
  check.equal(r.status, "failure")
  check.equal(r.failure_kind, "throw")
  local assertion = scenario("message_category")
  check.equal(assertion.status, "failure")
  check.equal(assertion.failure_kind, "assertion", "message text cannot classify a failure")
end
