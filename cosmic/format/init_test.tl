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
local function test_basic_lua_formatting()
  assert_format(
    "local function hello(  x,y  )\nreturn x +   y\nend\n",
    "local function hello(x, y)\n  return x + y\nend\n",
    "basic lua formatting"
  )
end

-- Test syntax error rejection
local function test_syntax_error_rejection()
  assert_format_fails("if if if\n", "should reject syntax errors")
end

-- Test empty input
local function test_empty_input()
  assert_format("", "", "empty input")
end

-- Test idempotence on already-formatted code
local function test_idempotence_on_already_formatted_code()
  assert_idempotent(
    "local function foo(x, y)\n  if x then\n    return y\n  else\n    return x\n  end\nend\n",
    "idempotent on clean input"
  )
end

-- Test if/elseif/else/end indentation
local function test_if_elseif_else_end_indentation()
  assert_format(
    "if x > 0 then\nprint(\"positive\")\nelseif x < 0 then\nprint(\"negative\")\nelse\nprint(\"zero\")\nend\n",
    "if x > 0 then\n  print(\"positive\")\nelseif x < 0 then\n  print(\"negative\")\nelse\n  print(\"zero\")\nend\n",
    "if/elseif/else indentation"
  )
end

-- Test nested indentation
local function test_nested_indentation()
  assert_format(
    "local function foo()\nif true then\nif false then\nreturn 1\nend\nend\nend\n",
    "local function foo()\n  if true then\n    if false then\n      return 1\n    end\n  end\nend\n",
    "nested indentation"
  )
end

-- Test no space before ( in function calls
local function test_no_space_before_paren_in_calls()
  assert_format(
    "print  (\"hello\")\nfoo  ()\nmath.sqrt  (4)\n",
    "print(\"hello\")\nfoo()\nmath.sqrt(4)\n",
    "no space before ( in function calls"
  )
end

-- Test same-line {} doesn't cause indent drift
local function test_same_line_braces_no_indent_drift()
  assert_format(
    "local t = {a = 1, b = 2}\nlocal x = 42\n",
    "local t = {a = 1, b = 2}\nlocal x = 42\n",
    "inline table no indent drift"
  )
end

-- Test multi-line table indentation
local function test_multiline_table_indentation()
  assert_format(
    "local t = {\na = 1,\nb = 2,\n}\nlocal after = true\n",
    "local t = {\n  a = 1,\n  b = 2,\n}\nlocal after = true\n",
    "multi-line table indentation"
  )
end

-- Test repeat/until
local function test_repeat_until()
  assert_format(
    "repeat\nx = x + 1\nuntil x > 10\n",
    "repeat\n  x = x + 1\nuntil x > 10\n",
    "repeat/until indentation"
  )
end

-- Test comment preservation
local function test_comment_preservation()
  assert_format(
    "-- header comment\nlocal x = 1 -- inline\n",
    "-- header comment\nlocal x = 1 -- inline\n",
    "comment preservation"
  )
end

-- Test blank line collapsing (at most 1 blank line)
local function test_blank_line_collapsing()
  assert_format(
    "local x = 1\n\n\n\nlocal y = 2\n",
    "local x = 1\n\nlocal y = 2\n",
    "blank line collapsing"
  )
end

-- Test shebang preservation
local function test_shebang_preservation()
  assert_format(
    "#!/usr/bin/env cosmic\nlocal x = 42\n",
    "#!/usr/bin/env cosmic\nlocal x = 42\n",
    "shebang preservation"
  )
end

-- `record` in ACCESS and CALL positions is not a declaration: a field
-- access (`work.record(...)`), a call's own name (`record(x)`), and a
-- bare reference in an argument list must not open a block. The `=`/`:`
-- disambiguation already covers keys; these cover the sites found the
-- day the `-c` verbs moved behind a module with a `record` field, when
-- every line after `work.record(args)` acquired one indent forever.
local function test_record_identifier_not_a_declaration()
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
end

-- Test Teal record indentation
local function test_teal_record_indentation()
  assert_format(
    "local record Point\nx: number\ny: number\nend\n",
    "local record Point\n  x: number\n  y: number\nend\n",
    "teal record indentation",
    "test.tl"
  )
end

-- Test Teal enum
local function test_teal_enum_indentation()
  assert_format(
    "local enum Color\n\"red\"\n\"green\"\n\"blue\"\nend\n",
    "local enum Color\n  \"red\"\n  \"green\"\n  \"blue\"\nend\n",
    "teal enum indentation",
    "test.tl"
  )
end

-- Test determinism (same input always same output)
local function test_determinism()
  local input = "local function   messy(a,b  ,c)\nlocal   x=a+b\nreturn  x\nend\n"
  local r1 = fmt.format(input, "test.lua")
  local r2 = fmt.format(input, "test.lua")
  assert(r1.ok and r2.ok, "determinism: both should succeed")
  assert(r1.code == r2.code, "determinism: outputs should match")
end

-- Test format_file with missing file
local function test_format_file_missing_file()
  local result = fmt.format_file("/nonexistent/file.lua")
  assert(not result.ok, "format_file should fail on missing file")
  assert(result.errors[1].message:find("cannot open"), "should report file open error")
end

-- Test format_issues
local function test_format_issues()
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
local function test_idempotence_on_messy_input()
  assert_idempotent(
    "local function   messy(a,b  ,c)\nif a>0  then\nlocal   x=a+b\nreturn  x\nelse\nreturn -1\nend\nend\n",
    "idempotent on messy input"
  )
end

-- Test for/in loop
local function test_for_in_loop()
  assert_format(
    "for k, v in pairs(t) do\nprint(k, v)\nend\n",
    "for k, v in pairs(t) do\n  print(k, v)\nend\n",
    "for/in loop indentation"
  )
end

-- Test while loop
local function test_while_loop()
  assert_format(
    "while x > 0 do\nx = x - 1\nend\n",
    "while x > 0 do\n  x = x - 1\nend\n",
    "while loop indentation"
  )
end

-- Test method call chain
local function test_method_call_chain()
  assert_format(
    "spawn.spawn({cmd}):read()\n",
    "spawn.spawn({cmd}):read()\n",
    "method call chain"
  )
end

-- Complex record with function types AND function definitions
local function test_record_with_func_type_and_func_def()
  assert_format(
    "local record M\n  run: function(string): boolean\nend\nlocal function foo()\nreturn true\nend\n",
    "local record M\n  run: function(string): boolean\nend\nlocal function foo()\n  return true\nend\n",
    "record with func type then func def",
    "test.tl"
  )
end
