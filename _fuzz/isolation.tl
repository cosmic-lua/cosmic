--- Own one fuzz subprocess, its environment, captures and temporary directory.
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local testprocess = require("_tool.testprocess")

local record Request
  argv: {string}
  name: string
  seed: integer
  iters: integer
  timeout_ms: integer
  diagnostic: boolean
end

local enum Kind
  "pass"
  "crash"
  "failure"
  "timeout"
  "infrastructure"
end

-- signal/exit_code retain observations, including supervisor termination.
-- Only crash implies a native signal without timeout or infrastructure error.
-- detail is nonempty on failures; checkpoint_bytes is empty until decoding lands.
local record Outcome
  kind: Kind
  signal: integer | nil
  exit_code: integer | nil
  stdout: string
  stderr: string
  detail: string
  checkpoint_bytes: string
end

--- Classify process evidence without spawning or reconstructing inputs.
--- @param result testprocess.Result Supervisor observations
--- @return Outcome Errors and timeout evidence outrank a native signal
local function classify(result: testprocess.Result): Outcome
  local details: {string} = {}
  if result.start_error ~= "" then details[#details + 1] = result.start_error end
  if result.cleanup_error ~= "" then details[#details + 1] = result.cleanup_error end
  if result.timed_out then details[#details + 1] = "timed out" end
  local kind: Kind
  if result.start_error ~= "" or result.cleanup_error ~= "" then
    kind = "infrastructure"
  elseif result.timed_out then
    kind = "timeout"
  elseif result.signal ~= nil then
    kind = "crash"
  elseif result.exit_code == 0 then
    kind = "pass"
  else
    kind = "failure"
    details[#details + 1] = ("child exited %d without a diagnostic"):format(result.exit_code)
  end
  if kind ~= "pass" then
    details[#details + 1] = "exit_code=" .. tostring(result.exit_code)
    if result.signal ~= nil then
      details[#details + 1] = "signal=" .. tostring(result.signal)
    end
  end
  return {
    kind = kind, signal = result.signal, exit_code = result.exit_code,
    stdout = result.stdout, stderr = result.stderr,
    detail = table.concat(details, "; "), checkpoint_bytes = "",
  }
end

--- Run once in a fresh directory, then remove it after reading captures.
--- @param request Request Command, property identity and deadline
--- @return Outcome Classified process evidence, including cleanup failures
local function run(request: Request): Outcome
  local dir, err = fs.temp_dir()
  if not dir then
    return {
      kind = "infrastructure", stdout = "", stderr = "",
      detail = "temporary directory: " .. tostring(err or "creation failed"),
      checkpoint_bytes = "",
    }
  end
  local overrides: {string: string} = {
    FUZZ_ISOLATE = request.name,
    FUZZ_SEED = tostring(request.seed),
    FUZZ_ITERS = tostring(request.iters),
  }
  if request.diagnostic then overrides.FUZZ_DIAGNOSTIC_DIR = dir end
  local result = testprocess.run(request.argv, {
      env = env.list({drop = {"FUZZ_DIAGNOSTIC_DIR"}, set = overrides}),
      temp_dir = dir, timeout_ms = request.timeout_ms,
    })
  local outcome = classify(result)
  local removed, remove_err = fs.remove_all(dir)
  if not removed then
    outcome.kind = "infrastructure"
    outcome.detail = outcome.detail .. "; temporary directory cleanup: " ..
    tostring(remove_err or "removal failed") .. "; exit_code=" .. tostring(outcome.exit_code) ..
    "; signal=" .. tostring(outcome.signal)
  end
  return outcome
end

local record IsolationModule
  type Request = Request
  type Outcome = Outcome
  type Kind = Kind
  classify: function(result: testprocess.Result): Outcome
  run: function(request: Request): Outcome
end

local M: IsolationModule = {classify = classify, run = run}
return M
