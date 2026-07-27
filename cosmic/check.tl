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
  local s, err = codec.encode_lua(v)
  if s == nil then
    return "<unrenderable: " .. tostring(err) .. ">"
  end
  return s
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
  local ta = a as {any: any} -- cast: from any
  local tb = b as {any: any} -- cast: from any
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
--- Generic over the compared type: comparing values of different types
--- (a Stat against a string, a number against a boolean) fails at
--- check time instead of always-unequal at runtime.
--- @param actual T The value produced by the code under test
--- @param expected T The value it should equal
--- @param label string? Optional label prepended to the failure message
local function eq<T>(actual: T, expected: T, label?: string)
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
--- @param actual T The value produced by the code under test
--- @param expected T The value it should not equal
--- @param label string? Optional label prepended to the failure message
local function ne<T>(actual: T, expected: T, label?: string)
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
--- @param e string The second return value (expected to be a non-empty string)
--- @param label string? Optional label prepended to the failure message
local function err(value: any, e: string, label?: string)
  local msg: string
  if value ~= nil then
    msg = string.format("err failed: expected nil value, got %s", render(value))
  elseif not e or e == "" then
    msg = "err failed: expected non-empty error string, got " .. render(e)
  end
  if msg then
    if label then
      msg = label .. ": " .. msg
    end
    error(msg, 2)
  end
end

--- Assert a fallible return and narrow away nil.
--- The one sanctioned narrowing hole for tests and examples: tl 0.24.8
--- does not flow-narrow record unions through `assert`, so without this
--- every fallible call site needs its own `assert(x) as T`. `must`
--- centralizes that unsoundness behind a runtime nil check. Lua passes multiple returns through, so
--- `must(fs.read(path))` fails with fs.read's own error string.
--- Like `assert`, must forwards extra returns past the second, so
--- `for p in check.must(fs.files(d)) do` keeps the 4th return — the
--- to-be-closed guard that releases directory handles on early break.
--- A plain `value, err` pair still collapses to the value alone, so
--- `print(check.must(fs.read(p)))` prints no trailing nil. The checker,
--- though, sees the declared three-value tuple: when must is the LAST
--- argument to another call, parenthesize to truncate it —
--- `table.insert(parts, (check.must(chunk)))`.
--- @param v T? The fallible value (nil on failure)
--- @param e string? Failure message; a `nil, err` pair fills this in
--- @param ... any Extra returns (iterator state, closing guard, ...)
--- @return T The value, known non-nil
--- @return string The second argument, forwarded when extras exist
--- @return any... The extra returns, forwarded unchanged
local function must<T>(v: T | nil, e?: string, ...: any): T, string, any ...
  if v == nil then
    error(e or "must failed: expected value, got nil", 2)
  end
  if select("#", ...) == 0 then
    return v
  end
  return v, e, ...
end

--- Report whether the enforcement lane is active.
--- True when COSMIC_ENFORCE=1, which the privileged, unsandboxed CI lane
--- (`--make enforce`) sets. In that mode a sandbox test that cannot
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

--- Declare a precondition a test needs, and say what to do without it.
---
--- The trap this closes: a test that prints "skip: …" and returns exits
--- 0, and the runner counts 0 as a PASS -- `status_of` reserves exit 2
--- for skip. So a suite whose fixtures went missing reports green while
--- testing nothing, which is how a gate quietly becomes decorative.
---
--- Locally the skip stands: a cold checkout should not fail for lacking
--- a build. In CI it is a hard failure, because there the precondition
--- is always provisioned and its absence means the provisioning broke,
--- not that the developer is mid-setup.
---
---     if not check.needs("the make engine", fs.isfile(make_bin)) then
---       return
---     end
---
--- @param what string What is missing, named for the message
--- @param ok boolean Whether the precondition holds
--- @return boolean True when the test may proceed
local function needs(what: string, present: boolean): boolean
  if present then
    return true
  end
  if os.getenv("CI") then
    error("precondition missing in CI: " .. what ..
      " -- provisioning is broken, or this test should not be gated on it", 2)
  end
  io.stderr:write("→ skip: " .. what .. " is missing\n")
  print("skip: " .. what .. " is missing")
  return false
end

--- Record that a sandbox test actually exercised real enforcement.
--- Writes a marker the enforce-lane tripwire counts to confirm the lane is
--- not a silent no-op (every test skipping would otherwise look green).
--- @param label string Short name of the mechanism that enforced
local function enforced(label: string)
  io.stderr:write("✓ enforce-ran: " .. label .. "\n")
end

local record CheckModule
  eq: function<T>(actual: T, expected: T, label?: string)
  ne: function<T>(actual: T, expected: T, label?: string)
  ok: function(value: any, label?: string)
  must: function<T>(v: T | nil, e?: string, ...: any): T, string, any ...
  err: function(value: any, e: string, label?: string)
  enforcing: function(): boolean
  skip: function(reason: string, strict?: boolean)
  needs: function(what: string, present: boolean): boolean
  enforced: function(label: string)
end

local M: CheckModule = {
  eq = eq,
  ne = ne,
  ok = ok,
  must = must,
  err = err,
  enforcing = enforcing,
  skip = skip,
  needs = needs,
  enforced = enforced,
}

return M
