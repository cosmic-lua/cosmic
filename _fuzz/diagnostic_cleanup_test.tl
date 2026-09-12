local check = require("cosmic.check")
local checkpoint = require("_fuzz.checkpoint")
local driver = require("_fuzz.driver")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local isolation = require("_fuzz.isolation")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local source = require("_fuzz.source")
local testprocess = require("_tool.testprocess")
local function contains(message: string, field: string)
  check.truthy(message:find(field, 1, true), "missing " .. field .. ": " .. message)
end
local function restore(name: string, value: string | nil)
  if value then assert(env.set(name, value)) else assert(env.unset(name)) end
end
local function test_healthy_run_launches_once_and_preserves_ambient_environment()
  local name = "healthy_launch"
  local selected = env.get("FUZZ_ISOLATE")
  if selected and selected ~= name then return end
  local trace = fs.join(os.getenv("TEST_TMPDIR"), "healthy-trace")
  local function run_property(): boolean, string
    return driver.run({name = name, iters = 3,
        gen = function(_rec: source.Recorder): string
          assert(env.get("FUZZ_DIAGNOSTIC_DIR") == nil)
          local old = fs.read(trace) or ""
          assert(fs.write(trace, old .. "g"))
          return "ok"
        end,
        check = function(_input: string): boolean, string
          local old = fs.read(trace) or ""
          assert(fs.write(trace, old .. "c"))
          return true
        end})
  end
  if selected then
    local _ok, _message = run_property()
    return
  end
  local sentinel_dir = check.must(fs.temp_dir())
  local sentinel = fs.join(sentinel_dir, "checkpoint")
  assert(fs.write(sentinel, "ambient"))
  local saved_seed, saved_iters = env.get("FUZZ_SEED"), env.get("FUZZ_ITERS")
  local saved_diag = env.get("FUZZ_DIAGNOSTIC_DIR")
  assert(env.set("FUZZ_SEED", "41"))
  assert(env.set("FUZZ_ITERS", "99"))
  assert(env.set("FUZZ_DIAGNOSTIC_DIR", sentinel_dir))
  local launches, real_run, ok, message = 0, isolation.run, false, ""
  check.swap_members(isolation, {run = function(request: isolation.Request): isolation.Outcome
        launches = launches + 1
        return real_run(request)
      end}, function()
      ok, message = run_property()
    end)
  restore("FUZZ_SEED", saved_seed)
  restore("FUZZ_ITERS", saved_iters)
  restore("FUZZ_DIAGNOSTIC_DIR", saved_diag)
  check.equal(ok, true)
  check.equal(message, "healthy_launch: 3 iterations, seed=41")
  check.equal(launches, 1)
  check.equal(check.must(fs.read(trace)), "gcgcgc")
  check.equal(check.must(fs.read(sentinel)), "ambient")
  assert(fs.remove_all(sentinel_dir))
end

local function run_hang_case(name: string, diagnostic_only: boolean): string, integer
  local selected = env.get("FUZZ_ISOLATE")
  local pid_path = fs.join(os.getenv("TEST_TMPDIR"), name .. "-pid")
  local launches, real_run, message = 0, isolation.run, ""
  check.swap_members(isolation, {run = function(request: isolation.Request): isolation.Outcome
        launches = launches + 1
        check.equal(request.timeout_ms, 100)
        return real_run(request)
      end}, function()
      local _, reported = driver.run({name = name, iters = 200, timeout_ms = 100,
          gen = function(_rec: source.Recorder): string
            if not diagnostic_only or env.get("FUZZ_DIAGNOSTIC_DIR") then
              assert(fs.write(pid_path, tostring(proc.getpid())))
              while true do end
            end
            return "crash"
          end,
          check = function(_input: string): boolean, string
            assert(signal.raise(signal.SIGTERM))
            return true
          end})
      message = reported
    end)
  if selected then return "", 0 end
  local parsed = tonumber(check.must(fs.read(pid_path)))
  local pid = assert(parsed and math.tointeger(parsed))
  check.equal(signal.kill(pid, 0), false, "direct child survived successful reap")
  return message, launches
end

local function test_initial_and_diagnostic_hangs_are_bounded_and_reaped()
  local initial, diagnostic = "initial_generation_hang", "diagnostic_generation_hang"
  local selected = env.get("FUZZ_ISOLATE")
  if selected then
    if selected == initial then
      local _message, _launches = run_hang_case(initial, false)
    elseif selected == diagnostic then
      local _message, _launches = run_hang_case(diagnostic, true)
    end
    return
  end
  local message, launches = run_hang_case(initial, false)
  check.equal(launches, 1)
  contains(message, "configured_iters=200: hung: exceeded 100ms; input=unavailable")
  message, launches = run_hang_case(diagnostic, true)
  check.equal(launches, 2)
  contains(message, "crashed: signal 15; original_input=unavailable")
  contains(message, "diagnostic=inconclusive; reason=timeout")
end

local function process_result(index: integer): testprocess.Result
  if index == 2 then
    return {exit_code = 137, signal = signal.SIGKILL, stdout = "", stderr = "",
      elapsed_ms = 1, timed_out = true, cleanup_error = "", start_error = ""}
  end
  if index == 3 then
    return {exit_code = 0, signal = nil, stdout = "", stderr = "",
      elapsed_ms = 1, timed_out = false, cleanup_error = "", start_error = ""}
  end
  return {exit_code = 143, signal = signal.SIGTERM, stdout = "", stderr = "",
    elapsed_ms = 1, timed_out = false, cleanup_error = "", start_error = ""}
end

local function request(): isolation.Request
  return {argv = {check.must(proc.interpreter()), "unused"}, name = "fresh",
    seed = 5, iters = 9, timeout_ms = 1000, diagnostic = true}
end

local function test_sequential_runs_use_fresh_directories_and_reject_stale_records()
  if env.get("FUZZ_ISOLATE") then return end
  local dirs: {string} = {}
  check.swap_members(testprocess, {run = function(_argv: {string},
          opts: testprocess.Options): testprocess.Result
        dirs[#dirs + 1] = opts.temp_dir
        if #dirs == 1 then
          assert(checkpoint.write(fs.join(opts.temp_dir, "checkpoint"), {
                seed = 5, iters = 9, iteration = 4, phase = 2, stage = 1,
                draws = 0, input = "first",
              }))
        end
        return process_result(#dirs)
      end}, function()
      local first = isolation.run(request())
      local second = isolation.run(request())
      local third = isolation.run(request())
      check.equal(first.kind, "crash")
      check.equal(second.kind, "timeout")
      check.equal(third.kind, "pass")
      check.equal(first.checkpoint and first.checkpoint.valid, true)
      check.equal(second.checkpoint and second.checkpoint.valid, false)
      check.equal(third.checkpoint and third.checkpoint.valid, false)
    end)
  check.not_equal(dirs[1], dirs[2])
  check.not_equal(dirs[2], dirs[3])
  check.not_equal(dirs[1], dirs[3])
  for _, dir in ipairs(dirs) do
    check.equal(fs.stat(dir), nil, "captures/checkpoint directory survived cleanup")
  end
end

local function test_selected_property_alone_can_write_a_checkpoint()
  if env.get("FUZZ_ISOLATE") then return end
  local names = {"selected_checkpoint", "sibling_checkpoint"}
  local dir = check.must(fs.temp_dir())
  local saved_isolate, saved_seed = env.get("FUZZ_ISOLATE"), env.get("FUZZ_SEED")
  local saved_iters, saved_diag = env.get("FUZZ_ITERS"), env.get("FUZZ_DIAGNOSTIC_DIR")
  assert(env.set("FUZZ_ISOLATE", names[1]))
  assert(env.set("FUZZ_SEED", "12"))
  assert(env.set("FUZZ_ITERS", "1"))
  assert(env.set("FUZZ_DIAGNOSTIC_DIR", dir))
  local writes: {checkpoint.Snapshot} = {}
  check.swap_members(checkpoint, {write = function(_path: string,
          snapshot: checkpoint.Snapshot): boolean, string
        writes[#writes + 1] = snapshot
        return true, ""
      end}, function()
      local sibling_ok, sibling_message = driver.run({name = names[2], iters = 8,
          gen = function(_rec: source.Recorder): string return "sibling" end,
          check = function(_input: string): boolean, string return true end})
      check.equal(sibling_ok, true)
      contains(sibling_message, "skipped (isolating a different property)")
      check.equal(#writes, 0)
      local selected_ok = driver.run({name = names[1], iters = 8,
          gen = function(_rec: source.Recorder): string return "selected" end,
          check = function(_input: string): boolean, string return true end})
      check.equal(selected_ok, true)
    end)
  restore("FUZZ_ISOLATE", saved_isolate)
  restore("FUZZ_SEED", saved_seed)
  restore("FUZZ_ITERS", saved_iters)
  restore("FUZZ_DIAGNOSTIC_DIR", saved_diag)
  check.equal(#writes, 3)
  for _, snapshot in ipairs(writes) do
    check.equal(snapshot.seed, 12)
    check.equal(snapshot.iters, 1)
    check.equal(snapshot.iteration, 1)
  end
  assert(fs.remove_all(dir))
end
