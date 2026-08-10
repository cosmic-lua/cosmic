--- Assertion helpers for tests with auto-formatted failure messages.
--- Functions in this module throw on failure (level 2) so the error points
--- at the caller's line, not inside this module. This is the one module
--- exempt from the never-throw doctrine, and `needs`/`reap` may exit
--- the process because the runner grades exit codes — the record is
--- docs/decisions/d23-check-throws.md; no other cosmic.* module may
--- throw or exit, so never require check from library code.
local cosmo = require("cosmo")
local proc = require("cosmic.proc")

--- The skip exit code: 0 pass, 2 skip, anything else fail — the
--- grammar every runner grades by. Defined HERE because check is the
--- public module a test names it through, and check may not require
--- the internal runner tree (#992: records is `_tool.records` now;
--- its EXIT_SKIP mirrors this one, and its test asserts they agree).
local EXIT_SKIP < const > = 2

--- Render any Lua value as a readable string using the Lua serializer.
--- @param v any The value to render
--- @return string Human-readable representation
local function render(v: any): string
  if v == nil then
    return "nil"
  end
  local s, err = cosmo.EncodeLua(v)
  if s == nil then
    return "<unrenderable: " .. tostring(err) .. ">"
  end
  return s
end

--- Deep equality check for tables; == for everything else.
--- @param a any First value
--- @param b any Second value
--- @return boolean True when a and b are deeply equal
local function deep_equal(a: any, b: any): boolean
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  local ta = a as {any: any} -- cast: from any
  local tb = b as {any: any} -- cast: from any
  for k, v in pairs(ta) do
    if not deep_equal(v, tb[k]) then
      return false
    end
  end
  for k, v in pairs(tb) do
    if not deep_equal(ta[k], v) then
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
local function equal<T>(actual: T, expected: T, label?: string)
  if deep_equal(actual, expected) then
    return
  end
  local msg = string.format("equal failed: expected %s, got %s",
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
local function not_equal<T>(actual: T, expected: T, label?: string)
  if not deep_equal(actual, expected) then
    return
  end
  local msg = string.format("not_equal failed: expected values to differ, but both are %s",
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
local function truthy(value: any, label?: string)
  if value then
    return
  end
  local msg = string.format("truthy failed: expected truthy, got %s", render(value))
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
local function failed(value: any, err: string, label?: string)
  local msg: string
  if value ~= nil then
    msg = string.format("failed: expected nil value, got %s", render(value))
  elseif not err or err == "" then
    msg = "failed: expected non-empty error string, got " .. render(err)
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
--- Declares ONE return (#1064), so it composes exactly where `assert`
--- does: `return check.must(sqlite.open(":memory:"))` and
--- `table.insert(parts, check.must(chunk))` both type-check, with no
--- parenthesis-truncation anywhere. There is nothing to forward past
--- slot 2, because a fallible return has two slots and no more (D20
--- rule 11, enforced by the `fallible-returns` lint) — a resource that
--- must be released rides on the returned record's `__close`, the way
--- `fs.find_iter` and `sqlite.Rows` do.
--- @param value T? The fallible value (nil on failure)
--- @param err string? Failure message; a `nil, err` pair fills this in
--- @return T The value, known non-nil
local function must<T>(value: T | nil, err?: string): T
  if value == nil then
    error(err or "must failed: expected value, got nil", 2)
  end
  return value
end

--- Report whether the enforcement lane is active.
--- True when COSMIC_ENFORCE=1. In that mode a sandbox test that cannot
--- exercise real enforcement must fail loudly rather than skip silently,
--- since there is no outer sandbox left to blame.
---
--- NOTHING SETS IT YET. `--make enforce` — a privileged, unsandboxed
--- lane — is a named, planned verb, and this is the mechanism waiting
--- for it, exercised by `check_assertions_test.tl` and by hand. Said
--- plainly because a switch that reads as live and is not is worse
--- than no switch: the skips it would escalate are silently tolerated
--- in every lane that runs today.
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
--- Callers still `return` after calling this; it does not exit the
--- process — it only RECORDS the enforcement gap (`needs` is the one
--- that exits).
--- @param reason string Why enforcement could not run
--- @param strict boolean? Escalate to failure under COSMIC_ENFORCE=1
local function enforce_skip(reason: string, strict?: boolean)
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
--- Say so by EXITING — which this function does itself: when the
--- precondition is missing it prints the skip and exits EXIT_SKIP, so
--- a caller cannot forget the exit and turn a skip into a silent
--- pass. When it returns at all, the precondition held.
---
---     check.needs("the make engine", fs.is_file(make_bin))
---
--- @param what string What is missing, named for the message
--- @param present boolean Whether the precondition holds
local function needs(what: string, present: boolean)
  if present then
    return
  end
  if os.getenv("CI") then
    error("precondition missing in CI: " .. what ..
      " -- provisioning is broken, or this test should not be gated on it", 2)
  end
  io.stderr:write("→ skip: " .. what .. " is missing\n")
  print("skip: " .. what .. " is missing")
  os.exit(EXIT_SKIP)
end

--- Reap a forked child and grade what its exit code said.
---
--- An exit code is the ONLY thing a forked child can tell its parent,
--- and a parent that discards it makes the fork a hole in the runner's
--- grading -- the runner grades the PARENT, and the parent exited 0.
--- Both faces of that are silent:
---
--- - a child exiting `EXIT_SKIP` has announced that its environment
---   cannot run the test, and the run reports a pass instead;
--- - a child exiting nonzero has failed, and what surfaces upstream is
---   whatever the parent trips over next -- an EOF from `recv` names
---   the wrong end of the connection.
---
--- A skip ends the FILE rather than the test, by the same argument
--- `needs` makes: the parent is asserting on half a conversation, and
--- the runner's grading reads only the exit code.
--- @param pid integer The child to reap
--- @param what string What the child was, for the message
local function reap(pid: integer, what: string)
  local wr, werr = proc.wait(pid)
  -- `proc.wait` is a raw passthrough, so a signal delivered to this
  -- process surfaces here as EINTR instead of being retried underneath.
  while wr == nil and werr and werr:find("EINTR", 1, true) do
    wr, werr = proc.wait(pid)
  end
  if wr == nil then
    error("waiting for " .. what .. ": " .. (werr or "wait failed"), 2)
  end
  local status = (wr as proc.WaitResult).status -- cast: record union after guard
  local code = 128
  if proc.WIFEXITED(status) then
    code = proc.WEXITSTATUS(status)
  elseif proc.WIFSIGNALED(status) then
    code = 128 + proc.WTERMSIG(status)
  end
  if code == EXIT_SKIP then
    io.stderr:write("→ skip: " .. what .. " cannot run here\n")
    print("skip: " .. what .. " cannot run here")
    os.exit(EXIT_SKIP)
  end
  if code ~= 0 then
    error(what .. " exited " .. code, 2)
  end
end

--- Record that a sandbox test actually exercised real enforcement.
--- Writes a marker the enforce-lane tripwire counts to confirm the lane is
--- not a silent no-op (every test skipping would otherwise look green).
--- @param label string Short name of the mechanism that enforced
local function enforced(label: string)
  io.stderr:write("✓ enforce-ran: " .. label .. "\n")
end

local record CheckModule
  EXIT_SKIP: integer
  equal: function<T>(actual: T, expected: T, label?: string)
  not_equal: function<T>(actual: T, expected: T, label?: string)
  truthy: function(value: any, label?: string)
  must: function<T>(value: T | nil, err?: string): T
  failed: function(value: any, err: string, label?: string)
  enforcing: function(): boolean
  enforce_skip: function(reason: string, strict?: boolean)
  needs: function(what: string, present: boolean)
  reap: function(pid: integer, what: string)
  enforced: function(label: string)
end

local M: CheckModule = {
  -- Exported so a test names the contract instead of writing `2`;
  -- the definition is at the top of this file, mirrored by
  -- `_tool.records` beside the runner that grades it (#992).
  EXIT_SKIP = EXIT_SKIP,
  equal = equal,
  not_equal = not_equal,
  truthy = truthy,
  must = must,
  failed = failed,
  enforcing = enforcing,
  enforce_skip = enforce_skip,
  needs = needs,
  reap = reap,
  enforced = enforced,
}

return M
