--- Own one fuzz subprocess, its environment, captures and temporary directory.
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local checkpoint = require("_fuzz.checkpoint")
local codec = require("cosmic.codec")
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
-- detail is nonempty on failures. checkpoint belongs only to a diagnostic child.
local record Outcome
  kind: Kind
  signal: integer | nil
  exit_code: integer | nil
  stdout: string
  stderr: string
  detail: string
  checkpoint: checkpoint.Decoded | nil
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
    detail = table.concat(details, "; "),
  }
end

local function stage_name(stage: integer): string
  if stage == 1 then return "primary" end
  if stage == 2 then return "shrink" end
  return "verify"
end

--- Render one diagnostic rerun without changing the original crash evidence.
--- @param outcome Outcome The diagnostic child's classified evidence
--- @param original_signal integer The original child's native signal
--- @return string Frozen diagnostic report fields
local function diagnostic_report(outcome: Outcome, original_signal: integer): string
  if outcome.kind ~= "crash" then
    if outcome.kind == "pass" then return "diagnostic=inconclusive; reason=clean-exit" end
    if outcome.kind == "failure" then
      return "diagnostic=inconclusive; reason=ordinary-failure"
    end
    if outcome.kind == "timeout" then return "diagnostic=inconclusive; reason=timeout" end
    return "diagnostic=inconclusive; reason=infrastructure-error: " .. outcome.detail
  end
  if outcome.signal ~= original_signal then
    return ("diagnostic=inconclusive; reason=changed-signal; diagnostic_signal=%s"):
    format(tostring(outcome.signal))
  end
  local decoded = outcome.checkpoint
  if not decoded then return "diagnostic=inconclusive; reason=missing-checkpoint" end
  if not decoded.valid then
    local reason = "malformed-checkpoint: " .. decoded.error
    if decoded.error:find("ENOENT", 1, true)
    or decoded.error:find("No such file", 1, true) then reason = "missing-checkpoint" end
    return "diagnostic=inconclusive; reason=" .. reason
  end
  local snapshot = decoded.snapshot
  if not snapshot then return "diagnostic=inconclusive; reason=malformed-checkpoint" end
  if snapshot.phase == 4 then return "diagnostic=inconclusive; reason=oversized-input" end
  if snapshot.phase ~= 2 then
    return ("diagnostic=inconclusive; reason=non-check-phase-%d"):format(snapshot.phase)
  end
  return ("diagnostic=reproduced; checkpoint_iteration=%d; checkpoint_stage=%s; " ..
    "checkpoint_input(base64)=%s; checkpoint_draws=%d; attribution=last-checkpoint"):
  format(snapshot.iteration, stage_name(snapshot.stage),
  codec.encode_base64(snapshot.input), snapshot.draws)
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
  if request.diagnostic then
    outcome.checkpoint = checkpoint.read(fs.join(dir, "checkpoint"),
      request.seed, request.iters)
  end
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
  diagnostic_report: function(outcome: Outcome, original_signal: integer): string
  run: function(request: Request): Outcome
end

local M: IsolationModule = {classify = classify,
  diagnostic_report = diagnostic_report, run = run}
return M
