#!/usr/bin/env cosmic
--- The closure-* half of the carried tl patch: a narrow survives into
--- a closure exactly when the name is assigned nowhere in the file.
--- Split from teal_narrowing_test.tl (485/500) and teal_test.tl
--- (493/500) by the 500-line file limit.
---
--- The scan scope is the CHUNK ROOT, and two of these pin why: the
--- anonymous shape was stock-unsound (widening against the closure's
--- own body missed a reassignment after the definition), and the
--- nearest-enclosing-body scope fails for a narrowed upvalue carried
--- into a closure that escapes its parent.

local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

local tmpdir = os.getenv("TEST_TMPDIR")

--- Check one source under the tree's checker.
--- @param name string File name inside TEST_TMPDIR
--- @param src string The source
--- @return boolean Whether it checked clean
--- @return string The joined error messages, empty when clean
local function checks(name: string, src: string): boolean, string
  local path = fs.join(tmpdir, name)
  assert(fs.write(path, src))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  return result.ok, table.concat(msgs, "; ")
end

-- The win: a guarded module-level name never assigned in the file
-- keeps its narrow inside a named closure — the guarded-value idiom
-- stops needing a cast. Stock widened every narrow at this boundary.
local function test_an_unassigned_narrow_carries_into_a_closure()
  local ok, msgs = checks("closure_carry.tl", [[
local function pick(): string | integer
  return "x"
end
local v = pick()
if not (v is string) then return end
local function use(): string
  return v
end
print(use())
]])
  assert(ok, "a never-assigned narrow must carry into the closure: " .. msgs)
end
test_an_unassigned_narrow_carries_into_a_closure()

-- An assignment anywhere in the file widens the narrow at the
-- boundary, wherever the assignment sits relative to the closure.
local function test_an_assignment_anywhere_widens_at_the_boundary()
  local ok = checks("closure_widen.tl", [[
local function pick(): string | integer
  return "x"
end
local v = pick()
if not (v is string) then return end
local function use(): string
  return v
end
v = pick()
print(use())
]])
  assert(not ok, "a reassigned name must widen at the closure boundary")
end
test_an_assignment_anywhere_widens_at_the_boundary()

-- The stock hole this closes: an ANONYMOUS closure used to widen only
-- names assigned inside its own body, so `v = 2` after the definition
-- never widened and the escaped closure ran on a stale narrow.
local function test_the_anonymous_reassignment_hole_is_closed()
  local ok = checks("closure_anon.tl", [[
local function pick(): string | integer
  return "x"
end
local v = pick()
if not (v is string) then return end
local use = function(): string
  return v
end
v = 2
print(use())
]])
  assert(not ok, "an anonymous closure must widen a reassigned name")
end
test_the_anonymous_reassignment_hole_is_closed()

-- Why the scan scope is the chunk and not the nearest enclosing body:
-- a narrowed upvalue carried into a child that ESCAPES its parent
-- goes stale when the outer scope reassigns after the parent returns.
local function test_an_escaped_child_does_not_keep_an_upvalue_narrow()
  local ok = checks("closure_escape.tl", [[
local function pick(): string | integer
  return "x"
end
local v = pick()
local function parent(): function(): string
  if not (v is string) then
    error("no")
  end
  local function child(): string
    return v
  end
  return child
end
local c = parent()
v = 2
print(c())
]])
  assert(not ok, "an escaped child must not keep a narrow the file reassigns")
end
test_an_escaped_child_does_not_keep_an_upvalue_narrow()

-- A global is not governed by this file: scope 1's vars table IS
-- env.globals, shared by every file checked in one environment, so
-- another module can assign `gv` and the scan of THIS chunk never
-- sees it. Treating scope 1 as always-assigned drops the narrow.
local function test_a_global_narrow_does_not_carry_into_a_closure()
  local ok = checks("closure_global.tl", [[
global gv: string | integer = "x"
local use: function(): string
if gv is string then
  use = function(): string return gv end
end
print(use())
]])
  assert(not ok, "a global narrow must not carry into a closure")
end
test_a_global_narrow_does_not_carry_into_a_closure()

-- The same at a NAMED function boundary, where stock tl widened
-- everything and the closure-* patch introduced the carry: a global
-- must not gain a narrow there either.
local function test_a_global_narrow_does_not_carry_into_a_named_function()
  local ok = checks("closure_global_named.tl", [[
global gv: string | integer = "x"
if not (gv is string) then return end
local function use(): string
  return gv
end
print(use())
]])
  assert(not ok, "a global narrow must not carry into a named function")
end
test_a_global_narrow_does_not_carry_into_a_named_function()

-- The over-approximation guard. env.globals also holds the stdlib, so
-- `self.st[1].vars[name] ~= nil` is TRUE for a local merely sharing a
-- name with a builtin, and would widen this sound narrow. The
-- declaring-scope walk finds `tostring` at the chunk's own scope, not
-- scope 1, so the narrow carries. tl warns on the shadow itself and
-- warnings are errors here, so the check is on the ERRORS: with the
-- naive test this source also reports
-- `in return value: got string | integer, expected string`.
local function test_a_local_shadowing_a_stdlib_global_still_carries()
  local _ok, msgs = checks("closure_shadow.tl", [[
local function pick(): string | integer
  return "x"
end
local tostring = pick()
if not (tostring is string) then return end
local function use(): string
  return tostring
end
print(use())
]])
  assert(msgs == "", "a local shadowing a stdlib global must keep its narrow: " .. msgs)
end
test_a_local_shadowing_a_stdlib_global_still_carries()

print("all closure carry tests passed")
