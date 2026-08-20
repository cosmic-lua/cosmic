local check = require("cosmic.check")
local codec = require("cosmic.codec")
local coverage = require("cosmic.coverage")
local driver = require("_fuzz.driver")
local env = require("cosmic.env")
local rand = require("cosmic.rand")
local signal = require("cosmic.signal")
local source = require("_fuzz.source")
local time = require("cosmic.time")

local saved_seed = env.get("FUZZ_SEED")
local saved_iters = env.get("FUZZ_ITERS")

-- The driver reads FUZZ_SEED and FUZZ_ITERS from the process environment,
-- so every test that touches them puts the ambient values back.
local function restore()
  if saved_seed then
    assert(env.set("FUZZ_SEED", saved_seed))
  else
    assert(env.unset("FUZZ_SEED"))
  end
  if saved_iters then
    assert(env.set("FUZZ_ITERS", saved_iters))
  else
    assert(env.unset("FUZZ_ITERS"))
  end
end

-- A property that records every input it sees and never holds.
local function always_fails(seen: {string}): driver.Options
  return {
    name = "always_fails",
    iters = 8,
    gen = function(src: source.Recorder): string
      return driver.bytes(src, 16)
    end,
    check = function(input: string): boolean, string
      seen[#seen + 1] = input
      return false, "always fails"
    end,
  }
end

local function test_same_seed_reproduces_the_same_failure()
  assert(env.set("FUZZ_SEED", "42"))
  local first: {string} = {}
  local ok_first, first_msg = driver.run_unisolated(always_fails(first))
  local second: {string} = {}
  local ok_second, second_msg = driver.run_unisolated(always_fails(second))
  restore()
  check.equal(ok_first, false, "expected a failing run")
  check.equal(ok_second, false, "expected a failing run")
  check.equal(first_msg, second_msg, "same seed reported different failures")
  check.truthy(first_msg:find("iteration=1", 1, true), "the loop should stop at the first failure")
  -- always_fails's check also runs against shrink's candidate inputs, so
  -- `seen` holds that exploration too; same seed shrinks identically.
  check.equal(#first, #second, "same seed should shrink identically")
  check.equal(first[1], second[1], "same seed generated different inputs")
  check.truthy(first_msg:find("seed=42", 1, true), "seed missing: " .. first_msg)
end
test_same_seed_reproduces_the_same_failure()

local function test_a_throwing_check_is_reported_as_a_failure()
  local ok, msg = driver.run_unisolated({
      name = "thrower",
      iters = 4,
      gen = function(_src: source.Recorder): string
        return "input"
      end,
      check = function(_input: string): boolean, string
        error("boom")
      end,
    })
  check.equal(ok, false, "a throw should fail the run")
  check.truthy(msg:find("boom", 1, true), "thrown error missing: " .. msg)
  check.truthy(msg:find("iteration=1", 1, true), "iteration missing: " .. msg)
end
test_a_throwing_check_is_reported_as_a_failure()

local function test_failure_message_carries_the_failing_input()
  assert(env.set("FUZZ_SEED", "7"))
  local seen: {string} = {}
  local ok, msg = driver.run_unisolated(always_fails(seen))
  restore()
  check.equal(ok, false, "expected a failing run")
  check.truthy(msg:find("seed=", 1, true), "seed missing: " .. msg)
  check.truthy(msg:find("iteration=", 1, true), "iteration missing: " .. msg)
  check.truthy(msg:find("draws=", 1, true), "draws missing: " .. msg)
  local encoded = msg:match("input%(base64%)=([A-Za-z0-9+/=]*)")
  check.truthy(encoded, "no base64 input in: " .. msg)
  -- the reported input is shrunk, so it need not equal the raw
  -- iteration-1 input any more -- just decode cleanly.
  check.must(codec.decode_base64(encoded))
end
test_failure_message_carries_the_failing_input()

local function test_failure_message_reports_a_minimized_input()
  assert(env.set("FUZZ_SEED", "5"))
  local ok, msg = driver.run_unisolated({
      name = "fails_over_two_bytes",
      iters = 32,
      gen = function(src: source.Recorder): string
        return driver.bytes(src, 256)
      end,
      check = function(input: string): boolean, string
        return #input <= 2, "too long"
      end,
    })
  restore()
  check.equal(ok, false, "expected a failing run")
  local encoded = msg:match("input%(base64%)=([A-Za-z0-9+/=]*)")
  check.truthy(encoded, "no base64 input in: " .. msg)
  check.truthy(#encoded <= 8, "input was not minimized, base64 length " .. #encoded)
end
test_failure_message_reports_a_minimized_input()

local function test_iters_option_overrides_the_environment()
  assert(env.set("FUZZ_ITERS", "99"))
  local calls = 0
  local ok, msg = driver.run_unisolated({
      name = "counted",
      iters = 5,
      gen = function(src: source.Recorder): string
        calls = calls + 1
        return driver.bytes(src, 8)
      end,
      check = function(_input: string): boolean, string
        return true
      end,
    })
  restore()
  check.truthy(ok, "expected a passing run: " .. msg)
  check.equal(calls, 5, "Options.iters did not override FUZZ_ITERS")
  check.truthy(msg:find("5 iterations", 1, true), "summary wrong: " .. msg)
end
test_iters_option_overrides_the_environment()

local function test_environment_supplies_iterations_and_the_default_seed()
  assert(env.set("FUZZ_ITERS", "3"))
  assert(env.unset("FUZZ_SEED"))
  local calls = 0
  local ok, msg = driver.run_unisolated({
      name = "from_env",
      gen = function(src: source.Recorder): string
        calls = calls + 1
        return driver.bytes(src, 4)
      end,
      check = function(_input: string): boolean, string
        return true
      end,
    })
  restore()
  check.truthy(ok, "expected a passing run: " .. msg)
  check.equal(calls, 3, "FUZZ_ITERS did not set the iteration count")
  check.truthy(msg:find("seed=1", 1, true), "default seed missing: " .. msg)
end
test_environment_supplies_iterations_and_the_default_seed()

local function test_bytes_respects_its_length_bound()
  local rec = source.new(rand.insecure_source(3))
  local longest = 0
  for _ = 1, 50 do
    local sample = driver.bytes(rec, 8)
    check.truthy(#sample <= 8, "too long: " .. tostring(#sample))
    if #sample > longest then
      longest = #sample
    end
  end
  check.truthy(longest > 0, "bytes never produced any output")
  check.equal(driver.bytes(rec, 0), "", "max_len 0 should produce an empty string")
end
test_bytes_respects_its_length_bound()

local function test_mutate_edits_the_sample()
  local rec = source.new(rand.insecure_source(5))
  local edited = 0
  for _ = 1, 50 do
    if driver.mutate(rec, "sample", 1) ~= "sample" then
      edited = edited + 1
    end
  end
  check.truthy(edited > 0, "mutate never changed the sample")
  check.equal(#driver.mutate(rec, "", 1), 1, "an edit on an empty string should insert")
end
test_mutate_edits_the_sample()

local function test_same_seed_draws_the_same_sequence()
  local a = source.new(rand.insecure_source(11))
  local b = source.new(rand.insecure_source(11))
  local input_a = driver.bytes(a, 32)
  local input_b = driver.bytes(b, 32)
  check.equal(input_a, input_b, "same seed should draw the same bytes")
  check.equal(#a.draws, #b.draws, "same seed should record the same draw count")
  for i, da in ipairs(a.draws) do
    local db = b.draws[i]
    check.equal(da.kind, db.kind, "draw " .. i .. " kind mismatch")
    check.equal(da.ivalue, db.ivalue, "draw " .. i .. " ivalue mismatch")
  end
end
test_same_seed_draws_the_same_sequence()

local function test_replay_regenerates_the_same_input()
  local rec = source.new(rand.insecure_source(19))
  local input = driver.bytes(rec, 24)
  local replayed = source.replay(rec.draws)
  local input2 = driver.bytes(replayed, 24)
  check.equal(input, input2, "replay should regenerate the same input")
  check.equal(#replayed.draws, #rec.draws, "replay should record the same draw count")
end
test_replay_regenerates_the_same_input()

local function test_replay_past_the_end_fails_by_position()
  local rec = source.new(rand.insecure_source(23))
  driver.bytes(rec, 4) -- record a short sequence
  local replayed = source.replay(rec.draws)
  local ok, err = pcall(function(): boolean
      for _ = 1, #rec.draws + 1 do
        replayed:int(0, 255)
      end
      return true
    end)
  check.equal(ok, false, "replay should fail once draws are exhausted")
  check.truthy(tostring(err):find(tostring(#rec.draws + 1), 1, true),
    "error should name the position, got: " .. tostring(err))
end
test_replay_past_the_end_fails_by_position()

-- The two budget tests below arm the driver's instruction hook, which
-- needs the VM's one hook slot: under the instrumented suite the
-- coverage collector owns it and the budget stands down, so they
-- bracket themselves with coverage.stop()/start() (nestable, counts
-- kept) to run meaningfully under both the plain and instrumented
-- suite.
local function without_coverage(body: function())
  local was_running = coverage.is_running()
  if was_running then
    coverage.stop()
  end
  body()
  if was_running then
    coverage.start()
  end
end

local function test_a_looping_property_fails_within_its_budget()
  without_coverage(function()
      local ok, msg = driver.run_unisolated({
          name = "looper",
          iters = 3,
          budget = 100000,
          gen = function(_src: source.Recorder): string
            return "input"
          end,
          check = function(_input: string): boolean, string
            while true do end
          end,
        })
      check.equal(ok, false, "a looping property must fail, not hang")
      check.truthy(msg:find("seed=", 1, true), "seed missing: " .. msg)
      check.truthy(msg:find("iteration=1", 1, true), "iteration missing: " .. msg)
      check.truthy(msg:find("budget=100000 exceeded", 1, true),
        "the budget failure is named: " .. msg)
    end)
end
test_a_looping_property_fails_within_its_budget()

local function test_a_terminating_property_passes_under_its_budget()
  local ok, msg = driver.run_unisolated({
      name = "well_within",
      iters = 8,
      budget = 100000,
      gen = function(src: source.Recorder): string
        return driver.bytes(src, 16)
      end,
      check = function(_input: string): boolean, string
        return true
      end,
    })
  check.truthy(ok, "a terminating property is unaffected by the budget: " .. msg)
end
test_a_terminating_property_passes_under_its_budget()

-- The budget hook must not outlive the run that armed it: after a
-- budget failure, a draw-heavy run whose TOTAL instruction count is far
-- past the previous small budget still completes, which it could not if
-- the old hook were still counting.
local function test_the_budget_hook_is_cleared_between_runs()
  without_coverage(function()
      local failed = driver.run_unisolated({
          name = "arms_a_tiny_budget",
          iters = 1,
          budget = 1000,
          gen = function(_src: source.Recorder): string
            return "input"
          end,
          check = function(_input: string): boolean, string
            while true do end
          end,
        })
      check.equal(failed, false, "the tiny-budget run must fail first")
      local ok, msg = driver.run_unisolated({
          name = "draw_heavy_afterwards",
          iters = 64,
          gen = function(src: source.Recorder): string
            return driver.bytes(src, 256)
          end,
          check = function(input: string): boolean, string
            return #input <= 256
          end,
        })
      check.truthy(ok, "the hook from the failed run must be gone: " .. msg)
    end)
end
test_the_budget_hook_is_cleared_between_runs()

-- The three tests below exercise driver.run() itself (not
-- run_unisolated), so each spawns at least one real child process via
-- cosmic.child — the mechanism the isolation item added.

-- Every test below calls driver.run() directly, and driver.run()
-- always spawns a child that re-executes this WHOLE file. So when
-- isolate() isolates test B's property, the child it spawns still
-- reaches test A's driver.run() call in file order — which correctly
-- reports "skipped" (see run()'s FUZZ_ISOLATE branch), the same
-- signal a real *_fuzz_test.tl's check.truthy(ok, msg) already treats
-- as a pass. A strict assertion here would not tolerate that; each
-- test below skips its own assertions when it detects this call ran
-- inside a SIBLING's isolated child instead of the top level.
local function skipped_by_a_sibling(msg: string): boolean
  return msg:find(": skipped (isolating a different property)", 1, true) ~= nil
end

local function test_a_crashing_check_is_attributed_to_its_iteration()
  local counter = 0
  local ok, msg = driver.run({
      name = "driver_test_crash_attribution",
      iters = 8,
      gen = function(_src: source.Recorder): string
        counter = counter + 1
        return tostring(counter)
      end,
      check = function(input: string): boolean, string
        if input == "5" then
          assert(signal.raise(signal.SIGSEGV))
        end
        return true
      end,
    })
  if ok and skipped_by_a_sibling(msg) then
    return
  end
  check.equal(ok, false, "a crashing property must fail: " .. tostring(msg))
  check.truthy(msg:find("crashed: signal", 1, true), "not reported as a crash: " .. msg)
  check.truthy(msg:find("iteration=5", 1, true), "wrong iteration attributed: " .. msg)
end
test_a_crashing_check_is_attributed_to_its_iteration()

local function test_a_hanging_check_is_reported_as_a_timeout()
  local ok, msg = driver.run({
      name = "driver_test_hang_timeout",
      iters = 1,
      timeout_ms = 200,
      gen = function(_src: source.Recorder): string
        return "input"
      end,
      check = function(_input: string): boolean, string
        -- A C-layer sleep, not a Lua loop: outside the VM instruction
        -- hook's reach, so only the wall-clock timeout catches it.
        check.must(time.sleep_ms(2000))
        return true
      end,
    })
  if ok and skipped_by_a_sibling(msg) then
    return
  end
  check.equal(ok, false, "a hanging property must fail: " .. tostring(msg))
  check.truthy(msg:find("hung: exceeded 200ms", 1, true), "not reported as a hang: " .. msg)
end
test_a_hanging_check_is_reported_as_a_timeout()

local function test_other_properties_in_the_file_are_skipped_when_isolating()
  local saved_isolate = env.get("FUZZ_ISOLATE")
  assert(env.set("FUZZ_ISOLATE", "some_other_property"))
  local called = false
  local ok, msg = driver.run({
      name = "driver_test_not_the_isolated_one",
      iters = 4,
      gen = function(_src: source.Recorder): string
        called = true
        return "input"
      end,
      check = function(_input: string): boolean, string
        called = true
        return true
      end,
    })
  if saved_isolate then
    assert(env.set("FUZZ_ISOLATE", saved_isolate))
  else
    assert(env.unset("FUZZ_ISOLATE"))
  end
  check.truthy(ok, "a skipped property must report ok: " .. tostring(msg))
  check.truthy(msg:find("skipped", 1, true), "not reported as skipped: " .. msg)
  check.equal(called, false, "gen/check must not run for a skipped property")
end
test_other_properties_in_the_file_are_skipped_when_isolating()
