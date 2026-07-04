--- Assertion helpers for tests with auto-formatted failure messages.
--- Functions in this module throw on failure (level 2) so the error points
--- at the caller's line, not inside this module.
local codec = require("cosmic.codec")

--- Render any Lua value as a readable string using the Lua serializer.
--- @param v any The value to render
--- @return string Human-readable representation
local function render(v: any): string
  if v == nil then
    return "nil"
  end
  return codec.encode_lua(v)
end

--- Deep equality check for tables; == for everything else.
--- @param a any First value
--- @param b any Second value
--- @return boolean True when a and b are deeply equal
local function deep_eq(a: any, b: any): boolean
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  local ta = a as {any: any}
  local tb = b as {any: any}
  for k, v in pairs(ta) do
    if not deep_eq(v, tb[k]) then
      return false
    end
  end
  for k, v in pairs(tb) do
    if not deep_eq(ta[k], v) then
      return false
    end
  end
  return true
end

--- Assert deep equality between actual and expected.
--- Uses deep comparison for tables, == for all other types.
--- Throws with a formatted message when the assertion fails.
--- @param actual any The value produced by the code under test
--- @param expected any The value it should equal
--- @param label string? Optional label prepended to the failure message
local function eq(actual: any, expected: any, label?: string)
  if deep_eq(actual, expected) then
    return
  end
  local msg = string.format("eq failed: expected %s, got %s",
    render(expected), render(actual))
  if label then
    msg = label .. ": " .. msg
  end
  error(msg, 2)
end

--- Assert that actual and expected are NOT equal.
--- Uses deep comparison for tables, == for all other types.
--- Throws with a formatted message when the assertion fails.
--- @param actual any The value produced by the code under test
--- @param expected any The value it should not equal
--- @param label string? Optional label prepended to the failure message
local function ne(actual: any, expected: any, label?: string)
  if not deep_eq(actual, expected) then
    return
  end
  local msg = string.format("ne failed: expected values to differ, but both are %s",
    render(actual))
  if label then
    msg = label .. ": " .. msg
  end
  error(msg, 2)
end

--- Assert that value is truthy (not nil and not false).
--- Throws with a formatted message when the assertion fails.
--- @param value any The value to test for truthiness
--- @param label string? Optional label prepended to the failure message
local function ok(value: any, label?: string)
  if value then
    return
  end
  local msg = string.format("ok failed: expected truthy, got %s", render(value))
  if label then
    msg = label .. ": " .. msg
  end
  error(msg, 2)
end

--- Assert that a (value, err) pair represents failure.
--- Expects value to be nil and err to be a non-nil, non-empty string,
--- matching the standard cosmic error-return convention.
--- @param value any The first return value (expected to be nil)
--- @param err string The second return value (expected to be a non-empty string)
--- @param label string? Optional label prepended to the failure message
local function err(value: any, e: string, label?: string)
  local msg: string
  if value ~= nil then
    msg = string.format("err failed: expected nil value, got %s", render(value))
  elseif not e or e == "" then
    msg = "err failed: expected non-empty error string, got " .. render(e as any)
  end
  if msg then
    if label then
      msg = label .. ": " .. msg
    end
    error(msg, 2)
  end
end

--- Report whether the enforcement lane is active.
--- True when COSMIC_ENFORCE=1, which the privileged, unsandboxed CI lane
--- (`bin/make enforce`) sets. In that mode a sandbox test that cannot
--- exercise real enforcement must fail loudly rather than skip silently,
--- since there is no outer sandbox left to blame.
--- @return boolean True when strict enforcement is required
local function enforcing(): boolean
  return os.getenv("COSMIC_ENFORCE") == "1"
end

--- Record that a sandbox test could not exercise real enforcement.
--- Writes a machine-readable marker to stderr so the enforce-lane tripwire
--- can see the skip (a silent `return` is indistinguishable from a pass).
--- When `strict` is set and enforcement is required (COSMIC_ENFORCE=1) the
--- skip is escalated to a hard failure — use `strict=true` only where the
--- mechanism was probed *available* yet the operation was still blocked,
--- which on the unsandboxed lane can only mean an outer sandbox is present.
--- Callers still `return` after calling this; it does not exit the process.
--- @param reason string Why enforcement could not run
--- @param strict boolean? Escalate to failure under COSMIC_ENFORCE=1
local function skip(reason: string, strict?: boolean)
  local tag = strict and "enforce-skip[strict]" or "enforce-skip"
  io.stderr:write("→ " .. tag .. ": " .. reason .. "\n")
  if strict and enforcing() then
    error("enforcement required but skipped: " .. reason, 2)
  end
end

--- Record that a sandbox test actually exercised real enforcement.
--- Writes a marker the enforce-lane tripwire counts to confirm the lane is
--- not a silent no-op (every test skipping would otherwise look green).
--- @param label string Short name of the mechanism that enforced
local function enforced(label: string)
  io.stderr:write("✓ enforce-ran: " .. label .. "\n")
end

local record AssertModule
  eq: function(actual: any, expected: any, label?: string)
  ne: function(actual: any, expected: any, label?: string)
  ok: function(value: any, label?: string)
  err: function(value: any, e: string, label?: string)
  enforcing: function(): boolean
  skip: function(reason: string, strict?: boolean)
  enforced: function(label: string)
end

local M: AssertModule = {
  eq = eq,
  ne = ne,
  ok = ok,
  err = err,
  enforcing = enforcing,
  skip = skip,
  enforced = enforced,
}

return M
