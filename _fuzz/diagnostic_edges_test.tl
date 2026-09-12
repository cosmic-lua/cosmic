local check = require("cosmic.check")
local driver = require("_fuzz.driver")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local signal = require("cosmic.signal")
local source = require("_fuzz.source")
local function child_for(name: string): boolean
  local selected = env.get("FUZZ_ISOLATE")
  return selected == nil or selected == name
end
local function contains(message: string, field: string)
  check.truthy(message:find(field, 1, true), "missing " .. field .. ": " .. message)
end
local function no_reported_input(message: string)
  check.equal(message:find("checkpoint_input", 1, true), nil, message)
  check.equal(message:find(" iteration=", 1, true), nil, message)
end
local function test_stateful_check_replays_the_prefix_without_parent_callbacks()
  local name = "diagnostic_check_mutates_state"
  if not child_for(name) then return end
  local oracle = fs.join(os.getenv("TEST_TMPDIR"), name .. "-oracle")
  local state = 0
  local ok, message = driver.run({name = name, iters = 6,
      gen = function(_rec: source.Recorder): string
        state = state + 1
        local input = tostring(state)
        if env.get("FUZZ_DIAGNOSTIC_DIR") then assert(fs.write(oracle, input)) end
        return input
      end,
      check = function(input: string): boolean, string
        state = state + 10
        if input == "23" then assert(signal.raise(signal.SIGTERM)) end
        return true
      end,
    })
  if env.get("FUZZ_ISOLATE") then return end
  check.equal(ok, false)
  for _, field in ipairs({"original_input=unavailable", "diagnostic=reproduced",
      "checkpoint_iteration=3", "checkpoint_stage=primary",
      "checkpoint_input(base64)=MjM=", "checkpoint_draws=0",
      "attribution=last-checkpoint"}) do contains(message, field) end
  check.equal(check.must(fs.read(oracle)), "23")
  check.equal(state, 0, "parent callbacks must remain untouched")
end

local function switch_result(name: string): string
  local marker = fs.join(os.getenv("TEST_TMPDIR"), name .. "-switch")
  local _, message = driver.run({name = name, iters = 1,
      gen = function(_rec: source.Recorder): string return "switch" end,
      check = function(_input: string): boolean, string
        if not fs.stat(marker) then
          assert(fs.write(marker, "original ran"))
          assert(signal.raise(signal.SIGTERM))
        end
        return true
      end,
    })
  return message
end

local function test_file_backed_change_makes_a_clean_rerun_inconclusive()
  local name = "diagnostic_switch_clean"
  if not child_for(name) then return end
  local message = switch_result(name)
  if env.get("FUZZ_ISOLATE") then return end
  contains(message, "crashed: signal 15; original_input=unavailable")
  contains(message, "diagnostic=inconclusive; reason=clean-exit")
  no_reported_input(message)
end

local function test_crash_while_generating_has_no_input_checkpoint()
  local name = "diagnostic_generating_crash"
  if not child_for(name) then return end
  local _, message = driver.run({name = name, iters = 2,
      gen = function(_rec: source.Recorder): string
        assert(signal.raise(signal.SIGTERM))
        return "unreachable"
      end,
      check = function(_input: string): boolean, string return true end,
    })
  if env.get("FUZZ_ISOLATE") then return end
  contains(message, "diagnostic=inconclusive; reason=non-check-phase-1")
  no_reported_input(message)
end

local function test_crash_in_shrink_generation_has_no_input_checkpoint()
  local name = "diagnostic_shrink_gen_crash"
  if not child_for(name) then return end
  local calls = 0
  local _, message = driver.run({name = name, iters = 1,
      gen = function(rec: source.Recorder): string
        calls = calls + 1
        if calls == 2 then assert(signal.raise(signal.SIGTERM)) end
        return tostring(rec:int(1, 9))
      end,
      check = function(_input: string): boolean, string return false, "shrink" end,
    })
  if env.get("FUZZ_ISOLATE") then return end
  contains(message, "diagnostic=inconclusive; reason=non-check-phase-1")
  no_reported_input(message)
  check.equal(calls, 0)
end

local function test_final_verification_checkpoint_has_its_stage_and_input()
  local name = "diagnostic_verify_crash"
  if not child_for(name) then return end
  local checks = 0
  local _, message = driver.run({name = name, iters = 1,
      gen = function(_rec: source.Recorder): string return "verify" end,
      check = function(_input: string): boolean, string
        checks = checks + 1
        if checks == 2 then assert(signal.raise(signal.SIGTERM)) end
        return false, "verify next"
      end,
    })
  if env.get("FUZZ_ISOLATE") then return end
  for _, field in ipairs({"diagnostic=reproduced", "checkpoint_iteration=1",
      "checkpoint_stage=verify", "checkpoint_input(base64)=dmVyaWZ5",
      "checkpoint_draws=0", "attribution=last-checkpoint"}) do
    contains(message, field)
  end
  check.equal(checks, 0)
end

local function test_real_empty_input_is_reported_from_a_valid_checkpoint()
  local name = "diagnostic_empty_input"
  if not child_for(name) then return end
  local _, message = driver.run({name = name, iters = 1,
      gen = function(_rec: source.Recorder): string return "" end,
      check = function(_input: string): boolean, string
        assert(signal.raise(signal.SIGTERM))
        return true
      end,
    })
  if env.get("FUZZ_ISOLATE") then return end
  contains(message, "diagnostic=reproduced")
  contains(message, "checkpoint_input(base64)=; checkpoint_draws=0")
  contains(message, "attribution=last-checkpoint")
end
