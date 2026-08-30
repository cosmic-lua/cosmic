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

-- An else block carries no condition, so the if-node's children table
-- starts at a nil hole with the branch body behind it. An `ipairs`
-- aggregate over those children stops at that hole, leaving the
-- subtree that carries this assignment invisible to the scan and the
-- narrow wrongly alive inside the closure — which is why the scan
-- reads them with `pairs`.
local function test_an_assignment_in_an_else_block_widens_at_the_boundary()
  local ok, msgs = checks("closure_widen_else.tl", [[
local function pick(): string | integer
  return "x"
end
local v = pick()
if not (v is string) then return end
local function use(): string
  return v
end
if os.time() > 0 then
  print(1)
else
  v = pick()
end
print(use())
]])
  assert(not ok, "an assignment in an else block must widen at the boundary")
  assert(msgs:find("in return value: got string | integer, expected string", 1, true), msgs)
end

-- A stepless `for i = a, b do` leaves the same kind of hole: the
-- missing step expression sits ahead of the body in the children
-- table, so an `ipairs` aggregate stops before the body and never
-- reaches the assignment inside it.
local function test_an_assignment_in_a_stepless_fornum_body_widens_at_the_boundary()
  local ok, msgs = checks("closure_widen_fornum.tl", [[
local function pick(): string | integer
  return "x"
end
local v = pick()
if not (v is string) then return end
local function use(): string
  return v
end
for _i = 1, 3 do
  v = pick()
end
print(use())
]])
  assert(not ok, "an assignment in a stepless fornum body must widen at the boundary")
  assert(msgs:find("in return value: got string | integer, expected string", 1, true), msgs)
end

-- The third hole is in an ASSIGNMENT STATEMENT's rvalue: `assignment`,
-- `local_declaration` and `global_declaration` all walk through
-- `walk_vars_exps` (o/3p/tl/tl.lua:5143-5152), which writes xs[1] from
-- `vars`, leaves xs[2] unset when there is no `decltuple` — and an
-- assignment statement never has one — then writes the rvalue
-- expressions into xs[3], behind that hole. A declaration always has a
-- decltuple, so only the assignment form exposes it.
local function test_an_assignment_in_an_assignment_rvalue_widens_at_the_boundary()
  local ok, msgs = checks("closure_widen_rvalue.tl", [[
local function pick(): string | integer
  return "x"
end
local v = pick()
if not (v is string) then return end
local function use(): string
  return v
end
local z: integer = 0
z = (function(): integer
  v = pick()
  return 1
end)()
print(use(), z)
]])
  assert(not ok, "an assignment in an assignment rvalue must widen at the boundary")
  assert(msgs:find("in return value: got string | integer, expected string", 1, true), msgs)
end

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

-- A global's narrow drops at a loop boundary too. Each of the four loop
-- forms widens against its own node, and a global is always-assigned
-- there, so the body -- which can run again after another module
-- assigns the global -- sees the union. Straight-line use above the
-- loop keeps its narrow, so exactly one diagnostic is expected per
-- source.
local function test_a_global_narrow_does_not_carry_into_a_loop_body()
  local diag = "cannot index key 'upper' in variable 'gv' of type string | integer"
  local forms: {{string}} = {
    {"while", "while os.time() < 0 do print(gv:upper()) end"},
    {"repeat", "repeat print(gv:upper()) until os.time() > 0"},
    {"forin", "for _k, _v in pairs({a = 1}) do print(gv:upper()) end"},
    {"fornum", "for _i = 1, 3 do print(gv:upper()) end"},
  }
  for _, form in ipairs(forms) do
    local ok, msgs = checks("closure_global_loop_" .. form[1] .. ".tl", [[
global gv: string | integer = "x"
if not (gv is string) then return end
print(gv:upper())
]] .. form[2] .. "\n")
    assert(not ok, "a global narrow must not carry into a " .. form[1] .. " body")
    local n, at = 0, 1
    while true do
      local i, j = msgs:find(diag, at, true)
      if not i then break end
      n, at = n + 1, j + 1
    end
    assert(n == 1, form[1] .. ": expected one diagnostic, got: " .. msgs)
  end
end

-- The chunk-root scan governs what the closure BODY may rely on. The
-- enclosing CONTINUATION after the definition is straight-line code,
-- so only an assignment inside the lambda's own body reaches it --
-- which is what stock kept here. The assignment below precedes the
-- guard, so the narrow at the use is sound and the lambda neither
-- reads nor assigns `v`.
local function test_a_lambda_does_not_widen_the_enclosing_continuation()
  local ok, msgs = checks("closure_continuation.tl", [[
local function pick(): string | integer
  return "x"
end
local v = pick()
v = pick()
if not (v is string) then return end
local cb = function(): integer return 1 end
print(cb())
print(v:upper())
]])
  assert(ok, "a lambda must not widen the enclosing continuation: " .. msgs)
end

-- The macroexp expression form is the other anonymous boundary, and
-- restores its continuation the same way.
local function test_a_record_macroexp_does_not_widen_the_continuation()
  local ok, msgs = checks("closure_continuation_macroexp.tl", [[
local function pick(): string | integer
  return "x"
end
local v = pick()
v = pick()
if not (v is string) then return end
local record R
  f: function(): integer = macroexp(): integer return 1 end
end
print(R.f())
print(v:upper())
]])
  assert(ok, "a record macroexp must not widen the continuation: " .. msgs)
end

-- What the continuation gives up: an assignment inside the lambda's
-- OWN body can run at any later point, so the narrow below the
-- definition still widens.
local function test_a_lambda_that_assigns_still_widens_the_continuation()
  local ok = checks("closure_continuation_assigns.tl", [[
local function pick(): string | integer
  return "x"
end
local v = pick()
v = pick()
if not (v is string) then return end
local cb = function() v = pick() end
cb()
print(v:upper())
]])
  assert(not ok, "a lambda that assigns must still widen the continuation")
end

-- The restore reaches the continuation only, never the body: the
-- anonymous twin of test_an_escaped_child_does_not_keep_an_upvalue_narrow,
-- which is the shape that runs through the changed boundary.
local function test_an_escaped_lambda_child_does_not_keep_an_upvalue_narrow()
  local ok = checks("closure_escape_anon.tl", [[
local function pick(): string | integer
  return "x"
end
local v = pick()
local parent = function(): function(): string
  if not (v is string) then
    error("no")
  end
  local child = function(): string
    return v
  end
  return child
end
local c = parent()
v = 2
print(c())
]])
  assert(not ok, "an escaped lambda child must not keep a narrow the file reassigns")
end

-- Only the two anonymous sites restore. Stock widened every narrow in
-- the continuation at the five named-function boundaries, so the
-- chunk-root scan is already strictly more permissive there and they
-- are left alone.
local function test_a_named_function_still_widens_the_continuation()
  local ok = checks("closure_continuation_named.tl", [[
local function pick(): string | integer
  return "x"
end
local v = pick()
v = pick()
if not (v is string) then return end
local function lf(): integer return 1 end
print(lf())
print(v:upper())
]])
  assert(not ok, "a named function must still widen the continuation")
end

print("all closure carry tests passed")
