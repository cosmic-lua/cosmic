local check = require("cosmic.check")
local codec = require("cosmic.codec")
local driver = require("_fuzz.driver")
local env = require("cosmic.env")

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
    gen = function(): string
      return driver.bytes(16)
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
  local ok_first, first_msg = driver.run(always_fails(first))
  local second: {string} = {}
  local ok_second, second_msg = driver.run(always_fails(second))
  restore()
  check.equal(ok_first, false, "expected a failing run")
  check.equal(ok_second, false, "expected a failing run")
  check.equal(first_msg, second_msg, "same seed reported different failures")
  check.equal(#first, 1, "the loop should stop at the first failure")
  check.equal(first[1], second[1], "same seed generated different inputs")
  check.truthy(first_msg:find("seed=42", 1, true), "seed missing: " .. first_msg)
end
test_same_seed_reproduces_the_same_failure()

local function test_a_throwing_check_is_reported_as_a_failure()
  local ok, msg = driver.run({
      name = "thrower",
      iters = 4,
      gen = function(): string
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
  local ok, msg = driver.run(always_fails(seen))
  restore()
  check.equal(ok, false, "expected a failing run")
  check.truthy(msg:find("seed=", 1, true), "seed missing: " .. msg)
  check.truthy(msg:find("iteration=", 1, true), "iteration missing: " .. msg)
  local encoded = msg:match("input%(base64%)=([A-Za-z0-9+/=]*)")
  check.truthy(encoded, "no base64 input in: " .. msg)
  local decoded = check.must(codec.decode_base64(encoded))
  check.equal(decoded, seen[1], "base64 did not decode to the failing input")
end
test_failure_message_carries_the_failing_input()

local function test_iters_option_overrides_the_environment()
  assert(env.set("FUZZ_ITERS", "99"))
  local calls = 0
  local ok, msg = driver.run({
      name = "counted",
      iters = 5,
      gen = function(): string
        calls = calls + 1
        return driver.bytes(8)
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
  local ok, msg = driver.run({
      name = "from_env",
      gen = function(): string
        calls = calls + 1
        return driver.bytes(4)
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
  math.randomseed(3)
  local longest = 0
  for _ = 1, 50 do
    local sample = driver.bytes(8)
    check.truthy(#sample <= 8, "too long: " .. tostring(#sample))
    if #sample > longest then
      longest = #sample
    end
  end
  check.truthy(longest > 0, "bytes never produced any output")
  check.equal(driver.bytes(0), "", "max_len 0 should produce an empty string")
end
test_bytes_respects_its_length_bound()

local function test_mutate_edits_the_sample()
  math.randomseed(5)
  local edited = 0
  for _ = 1, 50 do
    if driver.mutate("sample", 1) ~= "sample" then
      edited = edited + 1
    end
  end
  check.truthy(edited > 0, "mutate never changed the sample")
  check.equal(#driver.mutate("", 1), 1, "an edit on an empty string should insert")
end
test_mutate_edits_the_sample()
