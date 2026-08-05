#!/usr/bin/env cosmic
-- test cosmic.format module

local fmt = require("cosmic.format")
local check = require("cosmic.check")

local function assert_format(input: string, expected: string, msg: string, filename?: string)
  filename = filename or "test.lua"
  local result = fmt.format(input, filename)
  assert(result.ok, msg .. ": format failed: " .. (result.errors and #result.errors > 0
      and result.errors[1].message or "unknown error"))
  if result.code ~= expected then
    error(msg .. ":\n  expected:\n" .. expected .. "\n  got:\n" .. (result.code or "<nil>"))
  end
end

local function assert_format_fails(input: string, msg: string, filename?: string)
  filename = filename or "test.lua"
  local result = fmt.format(input, filename)
  assert(not result.ok, msg .. ": expected format to fail but it succeeded")
  assert(result.errors and #result.errors > 0, msg .. ": expected errors")
end

local function assert_idempotent(input: string, msg: string, filename?: string)
  filename = filename or "test.lua"
  local r1 = fmt.format(input, filename)
  assert(r1.ok, msg .. ": first format failed")
  local r2 = fmt.format(check.must(r1.code), filename)
  assert(r2.ok, msg .. ": second format failed")
  if r1.code ~= r2.code then
    error(msg .. ": not idempotent:\n  first:\n" .. (r1.code or "<nil>")
      .. "\n  second:\n" .. (r2.code or "<nil>"))
  end
end

-- Test basic Lua formatting
assert_format(
  "local function hello(  x,y  )\nreturn x +   y\nend\n",
  "local function hello(x, y)\n  return x + y\nend\n",
  "basic lua formatting"
)

-- Test syntax error rejection
assert_format_fails("if if if\n", "should reject syntax errors")

-- Test empty input
assert_format("", "", "empty input")

-- Test idempotence on already-formatted code
assert_idempotent(
  "local function foo(x, y)\n  if x then\n    return y\n  else\n    return x\n  end\nend\n",
  "idempotent on clean input"
)

-- Test if/elseif/else/end indentation
assert_format(
  "if x > 0 then\nprint(\"positive\")\nelseif x < 0 then\nprint(\"negative\")\nelse\nprint(\"zero\")\nend\n",
  "if x > 0 then\n  print(\"positive\")\nelseif x < 0 then\n  print(\"negative\")\nelse\n  print(\"zero\")\nend\n",
  "if/elseif/else indentation"
)

-- Test nested indentation
assert_format(
  "local function foo()\nif true then\nif false then\nreturn 1\nend\nend\nend\n",
  "local function foo()\n  if true then\n    if false then\n      return 1\n    end\n  end\nend\n",
  "nested indentation"
)

-- Test no space before ( in function calls
assert_format(
  "print  (\"hello\")\nfoo  ()\nmath.sqrt  (4)\n",
  "print(\"hello\")\nfoo()\nmath.sqrt(4)\n",
  "no space before ( in function calls"
)

-- Test same-line {} doesn't cause indent drift
assert_format(
  "local t = {a = 1, b = 2}\nlocal x = 42\n",
  "local t = {a = 1, b = 2}\nlocal x = 42\n",
  "inline table no indent drift"
)

-- Test multi-line table indentation
assert_format(
  "local t = {\na = 1,\nb = 2,\n}\nlocal after = true\n",
  "local t = {\n  a = 1,\n  b = 2,\n}\nlocal after = true\n",
  "multi-line table indentation"
)

-- Test repeat/until
assert_format(
  "repeat\nx = x + 1\nuntil x > 10\n",
  "repeat\n  x = x + 1\nuntil x > 10\n",
  "repeat/until indentation"
)

-- Test comment preservation
assert_format(
  "-- header comment\nlocal x = 1 -- inline\n",
  "-- header comment\nlocal x = 1 -- inline\n",
  "comment preservation"
)

-- Test blank line collapsing (at most 1 blank line)
assert_format(
  "local x = 1\n\n\n\nlocal y = 2\n",
  "local x = 1\n\nlocal y = 2\n",
  "blank line collapsing"
)

-- Test shebang preservation
assert_format(
  "#!/usr/bin/env cosmic\nlocal x = 42\n",
  "#!/usr/bin/env cosmic\nlocal x = 42\n",
  "shebang preservation"
)

-- Bug 1: function type annotations in records should NOT cause indent
assert_format(
  "local record R\n  a: function(x: number): string\n  b: function(y: string): number\n  c: number\nend\n",
  "local record R\n  a: function(x: number): string\n  b: function(y: string): number\n  c: number\nend\n",
  "function type in record no indent",
  "test.tl"
)

-- Bug 1 variant: function VALUE (not type) should still indent
assert_format(
  "local f = function(x)\nreturn x\nend\n",
  "local f = function(x)\n  return x\nend\n",
  "function value does indent"
)

-- `record` in ACCESS and CALL positions is not a declaration: a field
-- access (`work.record(...)`), a call's own name (`record(x)`), and a
-- bare reference in an argument list must not open a block. The `=`/`:`
-- disambiguation already covers keys; these cover the sites found the
-- day the `-c` verbs moved behind a module with a `record` field, when
-- every line after `work.record(args)` acquired one indent forever.
assert_format(
  "local a = work.record(x)\nlocal b = 1\n",
  "local a = work.record(x)\nlocal b = 1\n",
  "field access named record does not indent"
)
assert_format(
  "record(x)\nlocal b = 1\n",
  "record(x)\nlocal b = 1\n",
  "a call named record does not indent"
)
assert_format(
  "f(record, enum)\nlocal b = 1\n",
  "f(record, enum)\nlocal b = 1\n",
  "record as an argument does not indent"
)

-- Bug 1 variant: function definition should still indent
assert_format(
  "local function foo(x)\nreturn x\nend\n",
  "local function foo(x)\n  return x\nend\n",
  "function definition does indent"
)

-- Bug 2: method call colon should NOT get space
assert_format(
  "obj:method()\nself.x:find(\"a\")\nt[1]:close()\n",
  "obj:method()\nself.x:find(\"a\")\nt[1]:close()\n",
  "method call colon no space"
)

-- Bug 2 variant: type annotation colon SHOULD get space
assert_format(
  "local x:number = 1\n",
  "local x: number = 1\n",
  "type annotation colon gets space",
  "test.tl"
)

-- Bug 3: optional parameter ? should not get space before it
assert_format(
  "local function foo(x?: number)\nreturn x\nend\n",
  "local function foo(x?: number)\n  return x\nend\n",
  "optional param no space before ?",
  "test.tl"
)

-- Bug 5: unary minus should not get space
assert_format(
  "local x = -1\nlocal y = {-2, -3}\nfor i = 10, 1, -1 do\nend\n",
  "local x = -1\nlocal y = {-2, -3}\nfor i = 10, 1, -1 do\nend\n",
  "unary minus no space"
)

-- Bug 5: binary minus SHOULD still get space
assert_format(
  "local x = 10-5\n",
  "local x = 10 - 5\n",
  "binary minus gets space"
)

-- Test Teal record indentation
assert_format(
  "local record Point\nx: number\ny: number\nend\n",
  "local record Point\n  x: number\n  y: number\nend\n",
  "teal record indentation",
  "test.tl"
)

-- Test Teal enum
assert_format(
  "local enum Color\n\"red\"\n\"green\"\n\"blue\"\nend\n",
  "local enum Color\n  \"red\"\n  \"green\"\n  \"blue\"\nend\n",
  "teal enum indentation",
  "test.tl"
)

-- Test determinism (same input always same output)
do
  local input = "local function   messy(a,b  ,c)\nlocal   x=a+b\nreturn  x\nend\n"
  local r1 = fmt.format(input, "test.lua")
  local r2 = fmt.format(input, "test.lua")
  assert(r1.ok and r2.ok, "determinism: both should succeed")
  assert(r1.code == r2.code, "determinism: outputs should match")
end

-- Test format_file with missing file
do
  local result = fmt.format_file("/nonexistent/file.lua")
  assert(not result.ok, "format_file should fail on missing file")
  assert(result.errors[1].message:find("cannot open"), "should report file open error")
end

-- Test format_issues
do
  local issues = {{
      file = "test.lua",
      line = 1,
      column = 5,
      message = "syntax error",
      severity = "error",
    }}
  local s = fmt.format_issues(issues)
  assert(s == "test.lua:1:5: error: syntax error", "format_issues: " .. s)
end

-- Test idempotence on messy input
assert_idempotent(
  "local function   messy(a,b  ,c)\nif a>0  then\nlocal   x=a+b\nreturn  x\nelse\nreturn -1\nend\nend\n",
  "idempotent on messy input"
)

-- Test for/in loop
assert_format(
  "for k, v in pairs(t) do\nprint(k, v)\nend\n",
  "for k, v in pairs(t) do\n  print(k, v)\nend\n",
  "for/in loop indentation"
)

-- Test while loop
assert_format(
  "while x > 0 do\nx = x - 1\nend\n",
  "while x > 0 do\n  x = x - 1\nend\n",
  "while loop indentation"
)

-- Test method call chain
assert_format(
  "spawn.spawn({cmd}):read()\n",
  "spawn.spawn({cmd}):read()\n",
  "method call chain"
)

-- Complex record with function types AND function definitions
assert_format(
  "local record M\n  run: function(string): boolean\nend\nlocal function foo()\nreturn true\nend\n",
  "local record M\n  run: function(string): boolean\nend\nlocal function foo()\n  return true\nend\n",
  "record with func type then func def",
  "test.tl"
)

-- Bug 6: multi-line function call args should get continuation indent
assert_format(
  "local function foo()\n  assert(result == 0,\n    \"message\" ..\n    \"more\")\nend\n",
  "local function foo()\n  assert(result == 0,\n    \"message\" ..\n    \"more\")\nend\n",
  "multi-line call continuation indent"
)

-- Bug 6 variant: closing paren on own line dedents
assert_format(
  "foo(\n  x,\n  y\n)\n",
  "foo(\n  x,\n  y\n)\n",
  "multi-line call close paren dedents"
)

-- Bug 6 variant: single-line call unchanged
assert_format(
  "foo(x, y)\n",
  "foo(x, y)\n",
  "single-line call no indent change"
)

-- Bug 6 variant: nested multi-line calls
assert_format(
  "foo(\n  bar(\n    x\n  )\n)\n",
  "foo(\n  bar(\n    x\n  )\n)\n",
  "nested multi-line calls"
)

-- Bug 7: long string closing ]] followed by ) should stay on same line
assert_format(
  "local x = foo([[\nhello\n]])\n",
  "local x = foo([[\nhello\n]])\n",
  "long string close ]] with ) stays on same line"
)

-- Bug 7 variant: multiline long string with additional args before it
assert_format(
  "local x = bar(\"a\", [[\nhello\nworld\n]])\n",
  "local x = bar(\"a\", [[\nhello\nworld\n]])\n",
  "long string close ]] with ) after other args"
)

-- Bug 7 variant: long string followed by ) and , in nested call
assert_format(
  "local x = baz(qux([[\ninner\n]], \"after\"))\n",
  "local x = baz(qux([[\ninner\n]], \"after\"))\n",
  "long string close ]] with args after in nested call"
)

-- Bug 7 variant: long string followed by , in table
assert_format(
  "local t = {\n  key = [[\nvalue\n]],\n}\n",
  "local t = {\n  key = [[\nvalue\n]],\n}\n",
  "long string close ]] with comma in table"
)

-- Bug 7 variant: idempotent after formatting long string close
assert_idempotent(
  "local x = foo([[\nhello\n]])\n",
  "idempotent long string close"
)

-- Bug 7 variant: two consecutive long string args
assert_format(
  "local x = two([[\nfirst\n]], [[\nsecond\n]])\n",
  "local x = two([[\nfirst\n]], [[\nsecond\n]])\n",
  "two long string args stay on same line"
)

-- Bug 7 variant: already-split ]]\n) should be rejoined
assert_format(
  "local x = foo([[\nhello\n]]\n)\n",
  "local x = foo([[\nhello\n]])\n",
  "already-split long string close gets rejoined"
)

-- Bug 7 variant: already-split ]]\n) with indent should be rejoined
assert_format(
  "local function test()\n  local x = foo([[\nhello\n]]\n  )\nend\n",
  "local function test()\n  local x = foo([[\nhello\n]])\nend\n",
  "already-split long string close inside function gets rejoined"
)

-- Bug 7 variant: already-split ]]\n, should be rejoined
assert_format(
  "local x = bar([[\nhello\n]]\n, \"after\")\n",
  "local x = bar([[\nhello\n]], \"after\")\n",
  "already-split long string comma gets rejoined"
)

-- Bug 7 variant: long string not at end of line should NOT merge next line
assert_format(
  "local x = [[\nhello\n]]\nlocal y = 1\n",
  "local x = [[\nhello\n]]\nlocal y = 1\n",
  "long string assignment followed by new statement stays separate"
)

-- Bug 7 variant: long string followed by .. concatenation stays on same line
assert_format(
  "local s = [[\nhello\n]] .. body .. [[\nworld\n]]\n",
  "local s = [[\nhello\n]] .. body .. [[\nworld\n]]\n",
  "long string concat stays on same line"
)

-- Bug 7 variant: already-split long string .. concat gets rejoined
assert_format(
  "local s = [[\nhello\n]]\n\n  .. body .. [[\nworld\n]]\n",
  "local s = [[\nhello\n]] .. body .. [[\nworld\n]]\n",
  "already-split long string concat gets rejoined"
)

-- Bug 7 variant: long string concat inside function
assert_format(
  "local function run()\n  local s = [[\nfirst\n]] .. body .. [[\nsecond\n]]\n  return s\nend\n",
  "local function run()\n  local s = [[\nfirst\n]] .. body .. [[\nsecond\n]]\n  return s\nend\n",
  "long string concat inside function"
)

-- Bug: `as function(...)` type cast should not open a function block
assert_format(
  "local f = print as function(string)\nf(\"hello\")\n",
  "local f = print as function(string)\nf(\"hello\")\n",
  "as function cast no indent"
)

-- Bug variant: as function cast inside a function body
assert_format(
  "local function foo()\n  local f = print as function(string)\n  f(\"hello\")\nend\n\nfoo()\n",
  "local function foo()\n  local f = print as function(string)\n  f(\"hello\")\nend\n\nfoo()\n",
  "as function cast inside function body"
)

-- Bug variant: as function cast with multi-return type
assert_format(
  "local a = 1\nlocal b = 2\nlocal f = print as function(string): boolean, string\nlocal c = a + b\nprint(c)\n",
  "local a = 1\nlocal b = 2\nlocal f = print as function(string): boolean, string\nlocal c = a + b\nprint(c)\n",
  "as function cast with multi-return type"
)

-- Bug variant: as function cast with nested function types in signature
assert_format(
  "M.sa = unix.sa as function(number, function | number): (function | number, number)\nM.sp = unix.sp as function(number): number\nM.x = 1\n",
  "M.sa = unix.sa as function(number, function | number): (function | number, number)\nM.sp = unix.sp as function(number): number\nM.x = 1\n",
  "as function cast with nested function types"
)

print("All format tests passed!")
