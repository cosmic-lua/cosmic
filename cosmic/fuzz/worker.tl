--- Property workers use a parent-bound request and explicit completion record.
local child = require("cosmic.child")
local codec = require("cosmic.codec")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local loop = require("cosmic.fuzz.loop")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local storage = require("cosmic.fuzz.storage")
local types = require("cosmic.fuzz.types")
local budget = require("cosmic.fuzz.budget")

local MARKER = "COSMIC_FUZZ_WORKER"
local executing = false

local function timeout_for(opts: types.Options, iters: integer): integer
  return opts.timeout_ms or math.max(30000, iters * 10)
end

local function error_result(opts: types.Options, message: string): types.Result
  local r = storage.new(opts.name, opts.seed or 1)
  r.status, r.message = "error", message
  return r
end

--- Only a direct child of the request's owner may select a property.
--- A stale/ambient selector fails before any property can be skipped.
local function enter(opts: types.Options): types.Result | nil
  if executing then return error_result(opts, "nested fuzz.run is not supported") end
  local dir = env.get(MARKER)
  if not dir then return nil end
  local request, err = fs.read(fs.join(dir, "request"))
  if not request then return error_result(opts, "invalid worker request: " .. tostring(err)) end
  local pid, name, seed, iters, mode, encoded, limit, corpus = request:match(
    "^(%d+)\n([%w_.-]+)\n(%-?%d+)\n(%d+)\n(%a+)\n([^\n]*)\n(%d+)\n([^\n]*)$")
  if not pid or tonumber(pid) ~= proc.getppid() or (mode ~= "run" and mode ~= "replay") then
    return error_result(opts, "worker request does not belong to this process's parent")
  end
  if name ~= opts.name then
    local r = storage.new(opts.name, opts.seed or 1)
    r.status, r.message = "skipped", "another property is selected in this worker"
    return r
  end
  if fs.is_file(fs.join(dir, "result.json")) then
    return error_result(opts, "duplicate property name: " .. name)
  end
  opts.seed, opts.iters = math.tointeger(tonumber(seed)), math.tointeger(tonumber(iters))
  opts.budget = math.tointeger(tonumber(limit))
  local corpus_dir, corpus_err = codec.decode_base64(corpus)
  if not corpus_dir then return error_result(opts, tostring(corpus_err)) end
  opts.corpus_dir = corpus_dir
  if mode == "replay" then
    local input, why = codec.decode_base64(encoded)
    if not input then return error_result(opts, tostring(why)) end
    opts.replay_input = input
  else
    opts.replay_input = nil
  end
  executing = true
  local r = loop.run(opts, dir)
  executing = false
  local ok, why = storage.write(fs.join(dir, "result.json"), r)
  if not ok then return error_result(opts, "completion: " .. tostring(why)) end
  return r
end

local function supervise(opts: types.Options, dir: string): types.Result
  local executable, err = proc.interpreter()
  if not executable then return error_result(opts, "isolation unavailable: " .. tostring(err)) end
  local mode = opts.replay_input ~= nil and "replay" or "run"
  local request = string.format("%d\n%s\n%d\n%d\n%s\n%s\n%d\n%s", proc.getpid(),
    opts.name, opts.seed, opts.iters, mode, codec.encode_base64(opts.replay_input or ""),
    opts.budget or budget.default, codec.encode_base64(opts.corpus_dir or "testdata/fuzz"))
  local ok, why = fs.write(fs.join(dir, "request"), request)
  if not ok then return error_result(opts, "request: " .. tostring(why)) end
  local child_env = env.list({drop = {"FUZZ_ISOLATE"}, set = {[MARKER] = dir}})
  local argv: {string} = {executable}
  -- Packed entries already execute /zip/main.lua. Preserve dispatcher
  -- flags for examples and script arguments for application setup.
  if arg[0] ~= "/zip/main.lua" then argv[#argv + 1] = arg[0] end
  for _, value in ipairs(arg) do argv[#argv + 1] = value end
  local handle, start_err = child.start(argv, {env = child_env})
  if not handle then return error_result(opts, "start failed: " .. tostring(start_err)) end
  local limit = timeout_for(opts, opts.replay_input ~= nil and 1 or opts.iters)
  local result, wait_err = handle:wait(limit)
  if not result then
    -- wait(timeout) leaves a live handle: kill and reap BEFORE inspecting files.
    local stopped, stop_err = handle:stop(signal.SIGKILL)
    if not stopped then return error_result(opts, "stop failed: " .. tostring(stop_err)) end
    local reaped, reap_err = handle:wait()
    if not reaped then return error_result(opts, "reap failed: " .. tostring(reap_err)) end
    if wait_err ~= "timeout" then return error_result(opts, tostring(wait_err)) end
  elseif result.io_error then
    return error_result(opts, "worker I/O: " .. result.io_error)
  end
  if not result or result.signal then
    local original = storage.read(fs.join(dir, "original.json"))
    if original and original.status == "failure" then
      original.message = original.message .. "; shrinking interrupted by worker failure"
      return original
    end
    local captured, capture_err = storage.read(fs.join(dir, "current.json"))
    local r = captured or storage.new(opts.name, opts.seed)
    if captured and (r.name ~= opts.name or r.seed ~= opts.seed) then
      return error_result(opts, "capture identity mismatch")
    end
    r.status = result and "crash" or "timeout"
    r.signal = result and result.signal or 0
    r.message = result and ("crashed: signal " .. r.signal) or ("hung: exceeded " .. limit .. "ms")
    if not captured then r.message = r.message .. "; no input captured: " .. tostring(capture_err) end
    return r
  end
  local completed, completion_err = storage.read(fs.join(dir, "result.json"))
  if not completed then
    return error_result(opts, "worker did not complete: " .. tostring(completion_err)
      .. "; exit=" .. tostring(result.code) .. "; " .. (result.stderr or ""))
  end
  if completed.name ~= opts.name or completed.seed ~= opts.seed then
    return error_result(opts, "completion identity mismatch")
  end
  if completed.status == "pass" and not result.ok then
    return error_result(opts, "worker exited unsuccessfully after reporting pass")
  end
  if completed.status ~= "pass" and completed.status ~= "failure"
  and completed.status ~= "timeout" and completed.status ~= "error" then
    return error_result(opts, "invalid completion status: " .. completed.status)
  end
  return completed
end

return {enter = enter, supervise = supervise, timeout_for = timeout_for}
