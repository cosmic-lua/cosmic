local check = require("cosmic.check")
local checkpoint = require("_fuzz.checkpoint")
local driver = require("_fuzz.driver")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local isolation = require("_fuzz.isolation")
local signal = require("cosmic.signal")
local source = require("_fuzz.source")

local function sibling_child(name: string): boolean
  local selected = env.get("FUZZ_ISOLATE")
  return selected ~= nil and selected ~= name
end

local function assert_field(message: string, field: string)
  check.truthy(message:find(field, 1, true), "missing " .. field .. ": " .. message)
end

local function test_real_primary_crash_reports_the_diagnostic_child_input()
  local name = "diagnostic_primary_counter"
  if sibling_child(name) then return end
  local oracle = fs.join(os.getenv("TEST_TMPDIR"), "primary-oracle")
  local counter = 0
  local ok, message = driver.run({name = name, iters = 8,
      gen = function(_rec: source.Recorder): string
        counter = counter + 1
        local input = tostring(counter)
        if env.get("FUZZ_DIAGNOSTIC_DIR") then assert(fs.write(oracle, input)) end
        return input
      end,
      check = function(input: string): boolean, string
        if input == "5" then assert(signal.raise(signal.SIGTERM)) end
        return true
      end,
    })
  if env.get("FUZZ_ISOLATE") then return end
  check.equal(ok, false)
  for _, field in ipairs({"configured_iters=8: crashed: signal 15",
      "original_input=unavailable", "diagnostic=reproduced",
      "checkpoint_iteration=5", "checkpoint_stage=primary",
      "checkpoint_input(base64)=NQ==", "checkpoint_draws=0",
      "attribution=last-checkpoint"}) do assert_field(message, field) end
  check.equal(check.must(fs.read(oracle)), "5")
  check.equal(counter, 0, "the parent must not call gen")
end

local function test_real_shrink_crash_reports_the_candidate_and_draw_count()
  local name = "diagnostic_shrink_candidate"
  if sibling_child(name) then return end
  local oracle = fs.join(os.getenv("TEST_TMPDIR"), "shrink-oracle")
  local calls = 0
  local ok, message = driver.run({name = name, iters = 1,
      gen = function(rec: source.Recorder): string
        calls = calls + 1
        local input = tostring(rec:int(1, 5))
        if env.get("FUZZ_DIAGNOSTIC_DIR") then assert(fs.write(oracle, input)) end
        return input
      end,
      check = function(input: string): boolean, string
        if input == "1" then assert(signal.raise(signal.SIGTERM)) end
        return false, "shrink me"
      end,
    })
  if env.get("FUZZ_ISOLATE") then return end
  check.equal(ok, false)
  for _, field in ipairs({"original_input=unavailable", "diagnostic=reproduced",
      "checkpoint_iteration=1", "checkpoint_stage=shrink",
      "checkpoint_input(base64)=MQ==", "checkpoint_draws=1",
      "attribution=last-checkpoint"}) do assert_field(message, field) end
  check.equal(check.must(fs.read(oracle)), "1")
  check.equal(calls, 0, "the parent must not call gen")
end

local function fake_outcome(kind: isolation.Kind): isolation.Outcome
  return {kind = kind, signal = nil, exit_code = 0, stdout = "", stderr = "",
    detail = kind == "timeout" and "timed out" or "", checkpoint = nil}
end

local function fake_report(diagnostic: isolation.Outcome): string, integer
  local calls = 0
  local run = isolation.run
  isolation.run = function(request: isolation.Request): isolation.Outcome
    calls = calls + 1
    check.equal(request.diagnostic, calls == 2)
    if calls == 1 then
      local original = fake_outcome("crash")
      original.signal, original.exit_code = signal.SIGTERM, 143
      return original
    end
    return diagnostic
  end
  local parent_calls = 0
  local _, message = driver.run({name = "injected_diagnostic", iters = 4,
      gen = function(_rec: source.Recorder): string
        parent_calls = parent_calls + 1
        return "parent"
      end,
      check = function(_input: string): boolean, string
        parent_calls = parent_calls + 1
        return true
      end,
    })
  isolation.run = run
  check.equal(parent_calls, 0)
  return message, calls
end

local function test_one_rerun_and_inconclusive_diagnostic_outcomes()
  if env.get("FUZZ_ISOLATE") then return end
  local missing = fake_outcome("crash")
  missing.signal, missing.exit_code = signal.SIGTERM, 143
  local changed = fake_outcome("crash")
  changed.signal, changed.exit_code = signal.SIGSEGV, 139
  local cases: {{isolation.Outcome, string}} = {
    {missing, "reason=missing-checkpoint"},
    {changed, "reason=changed-signal; diagnostic_signal=11"},
    {fake_outcome("pass"), "reason=clean-exit"},
    {fake_outcome("timeout"), "reason=timeout"},
  }
  for _, case in ipairs(cases) do
    local message, calls = fake_report(case[1])
    check.equal(calls, 2, "one original plus one diagnostic")
    assert_field(message, case[2])
    assert_field(message, "original_input=unavailable")
    check.equal(message:find("checkpoint_input", 1, true), nil)
  end
end

local function with_selected(name: string, body: function())
  local saved_selected, saved_dir = env.get("FUZZ_ISOLATE"), env.get("FUZZ_DIAGNOSTIC_DIR")
  assert(env.set("FUZZ_ISOLATE", name))
  assert(env.set("FUZZ_DIAGNOSTIC_DIR", os.getenv("TEST_TMPDIR")))
  body()
  if saved_selected then assert(env.set("FUZZ_ISOLATE", saved_selected))
  else assert(env.unset("FUZZ_ISOLATE")) end
  if saved_dir then assert(env.set("FUZZ_DIAGNOSTIC_DIR", saved_dir))
  else assert(env.unset("FUZZ_DIAGNOSTIC_DIR")) end
end

local function test_observer_orders_every_primary_phase_and_unisolated_ignores_ambient()
  if env.get("FUZZ_ISOLATE") then return end
  local write = checkpoint.write
  local events: {string} = {}
  checkpoint.write = function(_path: string, snapshot: checkpoint.Snapshot): boolean, string
    events[#events + 1] = "write" .. snapshot.phase .. ":" .. snapshot.stage
    return true, ""
  end
  with_selected("phase_order", function()
      local ok = driver.run({name = "phase_order", iters = 1,
          gen = function(_rec: source.Recorder): string events[#events + 1] = "gen"; return "x" end,
          check = function(_input: string): boolean, string
            events[#events + 1] = "check"; return true
          end,
        })
      check.equal(ok, true)
    end)
  check.equal(table.concat(events, ","), "write1:1,gen,write2:1,check,write3:1")
  events = {}
  assert(env.set("FUZZ_DIAGNOSTIC_DIR", os.getenv("TEST_TMPDIR")))
  local ok = driver.run_unisolated({name = "ambient", iters = 1,
      gen = function(_rec: source.Recorder): string return "x" end,
      check = function(_input: string): boolean, string return true end})
  assert(env.unset("FUZZ_DIAGNOSTIC_DIR"))
  checkpoint.write = write
  check.equal(ok, true)
  check.equal(#events, 0)
end

local function test_write_failure_during_shrink_latches_before_more_callbacks()
  if env.get("FUZZ_ISOLATE") then return end
  local write, writes = checkpoint.write, 0
  checkpoint.write = function(_path: string, _snapshot: checkpoint.Snapshot): boolean, string
    writes = writes + 1
    if writes == 5 then return false, "injected shrink write failure" end
    return true, ""
  end
  local gen_calls, check_calls, message = 0, 0, ""
  with_selected("journal_latch", function()
      local ok = false
      ok, message = driver.run({name = "journal_latch", iters = 1,
          gen = function(rec: source.Recorder): string
            gen_calls = gen_calls + 1
            return tostring(rec:int(1, 5))
          end,
          check = function(_input: string): boolean, string
            check_calls = check_calls + 1
            return false, "counterexample"
          end,
        })
      check.equal(ok, false)
    end)
  checkpoint.write = write
  check.equal(writes, 5)
  check.equal(gen_calls, 2)
  check.equal(check_calls, 1)
  assert_field(message, "diagnostic journal failed: injected shrink write failure")
  check.equal(message:find("input(base64)", 1, true), nil)
end
