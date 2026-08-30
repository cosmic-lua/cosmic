#!/usr/bin/env cosmic
-- cosmic.format numbered-bug regression tests

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

-- Bug 1: function type annotations in records should NOT cause indent
local function test_bug1_function_type_in_record_no_indent()
  assert_format(
    "local record R\n  a: function(x: number): string\n  b: function(y: string): number\n  c: number\nend\n",
    "local record R\n  a: function(x: number): string\n  b: function(y: string): number\n  c: number\nend\n",
    "function type in record no indent",
    "test.tl"
  )
end

-- Bug 1 variant: function VALUE (not type) should still indent
local function test_bug1_variant_function_value_does_indent()
  assert_format(
    "local f = function(x)\nreturn x\nend\n",
    "local f = function(x)\n  return x\nend\n",
    "function value does indent"
  )
end

-- Bug 1 variant: function definition should still indent
local function test_bug1_variant_function_definition_does_indent()
  assert_format(
    "local function foo(x)\nreturn x\nend\n",
    "local function foo(x)\n  return x\nend\n",
    "function definition does indent"
  )
end

-- Bug 2: method call colon should NOT get space
local function test_bug2_method_call_colon_no_space()
  assert_format(
    "obj:method()\nself.x:find(\"a\")\nt[1]:close()\n",
    "obj:method()\nself.x:find(\"a\")\nt[1]:close()\n",
    "method call colon no space"
  )
end

-- Bug 2 variant: type annotation colon SHOULD get space
local function test_bug2_variant_type_annotation_colon_gets_space()
  assert_format(
    "local x:number = 1\n",
    "local x: number = 1\n",
    "type annotation colon gets space",
    "test.tl"
  )
end

-- Bug 3: optional parameter ? should not get space before it
local function test_bug3_optional_param_no_space_before_question()
  assert_format(
    "local function foo(x?: number)\nreturn x\nend\n",
    "local function foo(x?: number)\n  return x\nend\n",
    "optional param no space before ?",
    "test.tl"
  )
end

-- Bug 5: unary minus should not get space
local function test_bug5_unary_minus_no_space()
  assert_format(
    "local x = -1\nlocal y = {-2, -3}\nfor i = 10, 1, -1 do\nend\n",
    "local x = -1\nlocal y = {-2, -3}\nfor i = 10, 1, -1 do\nend\n",
    "unary minus no space"
  )
end

-- Bug 5: binary minus SHOULD still get space
local function test_bug5_binary_minus_gets_space()
  assert_format(
    "local x = 10-5\n",
    "local x = 10 - 5\n",
    "binary minus gets space"
  )
end

-- Bug 6: multi-line function call args should get continuation indent
local function test_bug6_multiline_call_continuation_indent()
  assert_format(
    "local function foo()\n  assert(result == 0,\n    \"message\" ..\n    \"more\")\nend\n",
    "local function foo()\n  assert(result == 0,\n    \"message\" ..\n    \"more\")\nend\n",
    "multi-line call continuation indent"
  )
end

-- Bug 6 variant: closing paren on own line dedents
local function test_bug6_variant_closing_paren_dedents()
  assert_format(
    "foo(\n  x,\n  y\n)\n",
    "foo(\n  x,\n  y\n)\n",
    "multi-line call close paren dedents"
  )
end

-- Bug 6 variant: single-line call unchanged
local function test_bug6_variant_single_line_call_unchanged()
  assert_format(
    "foo(x, y)\n",
    "foo(x, y)\n",
    "single-line call no indent change"
  )
end

-- Bug 6 variant: nested multi-line calls
local function test_bug6_variant_nested_multiline_calls()
  assert_format(
    "foo(\n  bar(\n    x\n  )\n)\n",
    "foo(\n  bar(\n    x\n  )\n)\n",
    "nested multi-line calls"
  )
end

-- Bug 7: long string closing ]] followed by ) should stay on same line
local function test_bug7_long_string_close_paren_same_line()
  assert_format(
    "local x = foo([[\nhello\n]])\n",
    "local x = foo([[\nhello\n]])\n",
    "long string close ]] with ) stays on same line"
  )
end

-- Bug 7 variant: multiline long string with additional args before it
local function test_bug7_variant_multiline_string_with_args_before()
  assert_format(
    "local x = bar(\"a\", [[\nhello\nworld\n]])\n",
    "local x = bar(\"a\", [[\nhello\nworld\n]])\n",
    "long string close ]] with ) after other args"
  )
end

-- Bug 7 variant: long string followed by ) and , in nested call
local function test_bug7_variant_long_string_paren_comma_nested_call()
  assert_format(
    "local x = baz(qux([[\ninner\n]], \"after\"))\n",
    "local x = baz(qux([[\ninner\n]], \"after\"))\n",
    "long string close ]] with args after in nested call"
  )
end

-- Bug 7 variant: long string followed by , in table
local function test_bug7_variant_long_string_comma_in_table()
  assert_format(
    "local t = {\n  key = [[\nvalue\n]],\n}\n",
    "local t = {\n  key = [[\nvalue\n]],\n}\n",
    "long string close ]] with comma in table"
  )
end

-- Bug 7 variant: idempotent after formatting long string close
local function test_bug7_variant_idempotent_long_string_close()
  assert_idempotent(
    "local x = foo([[\nhello\n]])\n",
    "idempotent long string close"
  )
end

-- Bug 7 variant: two consecutive long string args
local function test_bug7_variant_two_consecutive_long_string_args()
  assert_format(
    "local x = two([[\nfirst\n]], [[\nsecond\n]])\n",
    "local x = two([[\nfirst\n]], [[\nsecond\n]])\n",
    "two long string args stay on same line"
  )
end

-- Bug 7 variant: already-split ]]\n) should be rejoined
local function test_bug7_variant_already_split_close_paren_rejoined()
  assert_format(
    "local x = foo([[\nhello\n]]\n)\n",
    "local x = foo([[\nhello\n]])\n",
    "already-split long string close gets rejoined"
  )
end

-- Bug 7 variant: already-split ]]\n) with indent should be rejoined
local function test_bug7_variant_already_split_close_paren_indented_rejoined()
  assert_format(
    "local function test()\n  local x = foo([[\nhello\n]]\n  )\nend\n",
    "local function test()\n  local x = foo([[\nhello\n]])\nend\n",
    "already-split long string close inside function gets rejoined"
  )
end

-- Bug 7 variant: already-split ]]\n, should be rejoined
local function test_bug7_variant_already_split_comma_rejoined()
  assert_format(
    "local x = bar([[\nhello\n]]\n, \"after\")\n",
    "local x = bar([[\nhello\n]], \"after\")\n",
    "already-split long string comma gets rejoined"
  )
end

-- Bug 7 variant: long string not at end of line should NOT merge next line
local function test_bug7_variant_long_string_not_at_eol_stays_separate()
  assert_format(
    "local x = [[\nhello\n]]\nlocal y = 1\n",
    "local x = [[\nhello\n]]\nlocal y = 1\n",
    "long string assignment followed by new statement stays separate"
  )
end

-- Bug 7 variant: long string followed by .. concatenation stays on same line
local function test_bug7_variant_long_string_concat_same_line()
  assert_format(
    "local s = [[\nhello\n]] .. body .. [[\nworld\n]]\n",
    "local s = [[\nhello\n]] .. body .. [[\nworld\n]]\n",
    "long string concat stays on same line"
  )
end

-- Bug 7 variant: already-split long string .. concat gets rejoined
local function test_bug7_variant_already_split_concat_rejoined()
  assert_format(
    "local s = [[\nhello\n]]\n\n  .. body .. [[\nworld\n]]\n",
    "local s = [[\nhello\n]] .. body .. [[\nworld\n]]\n",
    "already-split long string concat gets rejoined"
  )
end

-- Bug 7 variant: long string concat inside function
local function test_bug7_variant_long_string_concat_inside_function()
  assert_format(
    "local function run()\n  local s = [[\nfirst\n]] .. body .. [[\nsecond\n]]\n  return s\nend\n",
    "local function run()\n  local s = [[\nfirst\n]] .. body .. [[\nsecond\n]]\n  return s\nend\n",
    "long string concat inside function"
  )
end

-- Bug: `as function(...)` type cast should not open a function block
local function test_bug_as_function_cast_no_indent()
  assert_format(
    "local f = print as function(string)\nf(\"hello\")\n",
    "local f = print as function(string)\nf(\"hello\")\n",
    "as function cast no indent"
  )
end

-- Bug variant: as function cast inside a function body
local function test_bug_variant_as_function_cast_inside_function_body()
  assert_format(
    "local function foo()\n  local f = print as function(string)\n  f(\"hello\")\nend\n\nfoo()\n",
    "local function foo()\n  local f = print as function(string)\n  f(\"hello\")\nend\n\nfoo()\n",
    "as function cast inside function body"
  )
end

-- Bug variant: as function cast with multi-return type
local function test_bug_variant_as_function_cast_multi_return_type()
  assert_format(
    "local a = 1\nlocal b = 2\nlocal f = print as function(string): boolean, string\nlocal c = a + b\nprint(c)\n",
    "local a = 1\nlocal b = 2\nlocal f = print as function(string): boolean, string\nlocal c = a + b\nprint(c)\n",
    "as function cast with multi-return type"
  )
end

-- Bug variant: as function cast with nested function types in signature
local function test_bug_variant_as_function_cast_nested_function_types()
  assert_format(
    "M.sa = unix.sa as function(number, function | number): (function | number, number)\nM.sp = unix.sp as function(number): number\nM.x = 1\n",
    "M.sa = unix.sa as function(number, function | number): (function | number, number)\nM.sp = unix.sp as function(number): number\nM.x = 1\n",
    "as function cast with nested function types"
  )
end
