#!/usr/bin/env cosmic
--- Tests for coverage executable-line analysis.
local cov_lines = require("cosmic.coverage.lines")

--- Compute lines for Lua source, asserting the parse succeeded.
local function lines_of(source: string, name: string): {integer: boolean}
  local result, err = cov_lines.executable_lines(source, name)
  assert(result, "parse failed: " .. (err or "?"))
  return result as {integer: boolean}
end

local function test_marks_basic_statements()
  local got = lines_of([[
local x = 1
x = x + 1
print(x)
return x
]], "basic.lua")
  assert(got[1], "local declaration not marked")
  assert(got[2], "assignment not marked")
  assert(got[3], "call statement not marked")
  assert(got[4], "return not marked")
end
test_marks_basic_statements()

local function test_skips_comments_and_blanks()
  local got = lines_of([[
-- a comment
local x = 1

-- another
x = 2
]], "comments.lua")
  assert(not got[1], "comment line marked")
  assert(got[2], "declaration not marked")
  assert(not got[3], "blank line marked")
  assert(not got[4], "comment line marked")
  assert(got[5], "assignment not marked")
end
test_skips_comments_and_blanks()

local function test_if_elseif_marked_else_not()
  local got = lines_of([[
local x = 1
if x > 0 then
  x = 2
elseif x < 0 then
  x = 3
else
  x = 4
end
]], "branches.lua")
  assert(got[2], "if line not marked")
  assert(got[3], "then-body not marked")
  assert(got[4], "elseif line not marked")
  assert(got[5], "elseif-body not marked")
  assert(not got[6], "bare else line marked")
  assert(got[7], "else-body not marked")
  assert(not got[8], "end line marked")
end
test_if_elseif_marked_else_not()

local function test_repeat_marks_until_line()
  local got = lines_of([[
local i = 0
repeat
  i = i + 1
until i > 2
]], "loop.lua")
  assert(not got[2], "repeat line marked")
  assert(got[3], "loop body not marked")
  assert(got[4], "until line not marked")
end
test_repeat_marks_until_line()

local function test_function_body_marked_definition_not()
  -- the VM attributes the closure instruction to the `end` line, so the
  -- definition line must stay out of the denominator
  local got = lines_of([[
local function f(n)
  return n + 1
end
local g = function()
  return 2
end
f(g())
]], "funcs.lua")
  assert(not got[1], "local function definition line marked")
  assert(got[2], "function body not marked")
  assert(not got[3], "end line marked")
  assert(got[4], "declaration with function value not marked")
  assert(got[5], "anonymous function body not marked")
  assert(got[7], "call statement not marked")
end
test_function_body_marked_definition_not()

local function test_loops_and_break()
  local got = lines_of([[
for i = 1, 3 do
  if i == 2 then
    break
  end
end
while true do
  goto out
end
::out::
]], "flow.lua")
  assert(got[1], "fornum not marked")
  assert(got[2], "nested if not marked")
  assert(got[3], "break not marked")
  assert(got[6], "while not marked")
  assert(got[7], "goto not marked")
  assert(not got[9], "label marked")
end
test_loops_and_break()

local function test_teal_type_declarations_not_marked()
  local got = lines_of([[
local record Point
  x: number
  y: number
end
local function dist(p: Point): number
  return p.x + p.y
end
return dist
]], "point.tl")
  assert(not got[1], "record declaration marked")
  assert(not got[2], "record field marked")
  assert(got[6], "teal function body not marked")
  assert(got[8], "teal return not marked")
end
test_teal_type_declarations_not_marked()

local function test_parse_failure_returns_nil()
  local result, err = cov_lines.executable_lines("local = = nonsense", "bad.lua")
  assert(result == nil, "expected nil for unparsable source")
  assert(err and #err > 0, "expected an error message")
end
test_parse_failure_returns_nil()
