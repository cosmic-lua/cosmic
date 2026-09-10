--- Resolve one test file's timeout and declared host capabilities.

local env = require("cosmic.env")
local fs = require("cosmic.fs")
local records = require("_tool.records")
local testcap = require("_tool.testcap")

local DEFAULT_TIMEOUT_MS < const > = 120000

local record Options
  timeout_ms: integer
  profile: string
  capabilities: {string: testcap.Availability}
  source_path: string
end

local record Plan
  timeout_ms: integer
  profile: string
  source_path: string
  unavailable: string
  detail: string
  fatal: boolean
  error: string
end

local function positive_integer(value: string, name: string): integer | nil, string
  local number = tonumber(value)
  local integer = number and math.tointeger(number)
  if not integer or integer <= 0 then
    return nil, name .. " must be a positive integer, got " .. tostring(value)
  end
  return integer
end

--- Resolve repository configuration and probe every declared requirement.
--- @param output_base string `.got` base identifying the test source
--- @param temp_dir string Per-test scratch directory for probes
--- @param opts Options? Hermetic overrides, primarily for runner tests
--- @return Plan The execution decision
local function resolve(output_base: string, temp_dir: string, opts?: Options): Plan
  local timeout_ms = opts and opts.timeout_ms or nil
  if not timeout_ms then
    local configured = env.get("COSMIC_TEST_TIMEOUT_MS")
    if configured and configured ~= "" then
      local parsed, err = positive_integer(configured, "COSMIC_TEST_TIMEOUT_MS")
      if not parsed then
        return {error = err, timeout_ms = 0, profile = "", source_path = "",
          unavailable = "", detail = "", fatal = true}
      end
      timeout_ms = parsed
    else
      timeout_ms = DEFAULT_TIMEOUT_MS
    end
  elseif timeout_ms <= 0 then
    return {error = "timeout_ms must be positive", timeout_ms = 0,
      profile = "", source_path = "", unavailable = "", detail = "", fatal = true}
  end

  local profile = opts and opts.profile or env.get("COSMIC_TEST_PROFILE") or "local"
  if profile ~= "local" and profile ~= "linux-ci" then
    return {error = "unknown test capability profile: " .. profile,
      timeout_ms = timeout_ms, profile = profile, source_path = "",
      unavailable = "", detail = "", fatal = true}
  end
  local source_path = opts and opts.source_path or records.source_of(output_base)
  local source = fs.read(source_path) or ""
  local requirements: {string} = {}
  local stage = records.stage_of(output_base)
  if stage == "test" or stage == "coverage" then
    requirements = testcap.declarations(source)
  end
  for _, name in ipairs(requirements) do
    local availability, perr = testcap.probe(name, temp_dir,
      opts and opts.capabilities or nil)
    if not availability then
      return {error = perr, timeout_ms = timeout_ms, profile = profile,
        source_path = source_path, unavailable = "", detail = "", fatal = true}
    end
    if not availability.available then
      local fatal, ferr = testcap.absence_is_fatal(name, profile)
      if ferr ~= "" then
        return {error = ferr, timeout_ms = timeout_ms, profile = profile,
          source_path = source_path, unavailable = "", detail = "", fatal = true}
      end
      return {timeout_ms = timeout_ms, profile = profile, source_path = source_path,
        unavailable = name, detail = availability.detail, fatal = fatal, error = ""}
    end
  end
  return {timeout_ms = timeout_ms, profile = profile, source_path = source_path,
    unavailable = "", detail = "", fatal = false, error = ""}
end

--- Stable evidence folded into the record tool stamp. This is deliberately
--- host-wide rather than source-specific: a capability transition has to
--- move make's prerequisite before a cached PASS can bypass `resolve`.
--- @param temp_dir string Writable probe directory
--- @param overrides {string: testcap.Availability}? Hermetic probe answers
--- @return string Public policy values and one availability bit per probe
local function policy_evidence(temp_dir: string,
    overrides?: {string: testcap.Availability}): string
  local rows: {string} = {
    "profile=" .. env.get_or("COSMIC_TEST_PROFILE", "local"),
    "timeout_ms=" .. env.get_or("COSMIC_TEST_TIMEOUT_MS",
      tostring(DEFAULT_TIMEOUT_MS)),
  }
  local names: {string} = {}
  for name in pairs(testcap.REQUIREMENTS) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local answer = testcap.probe(name, temp_dir, overrides)
    rows[#rows + 1] = name .. "=" ..
    (answer and answer.available and "available" or "unavailable")
  end
  return table.concat(rows, "\n") .. "\n"
end

local record TestPlanModule
  type Options = Options
  type Plan = Plan
  DEFAULT_TIMEOUT_MS: integer
  policy_evidence: function(temp_dir: string,
  overrides?: {string: testcap.Availability}): string
  resolve: function(output_base: string, temp_dir: string, opts?: Options): Plan
end

local M: TestPlanModule = {
  DEFAULT_TIMEOUT_MS = DEFAULT_TIMEOUT_MS,
  policy_evidence = policy_evidence,
  resolve = resolve,
}

return M
