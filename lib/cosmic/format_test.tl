#!/usr/bin/env cosmic
-- test cosmic --format option

local path = require("cosmo.path")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = path.join(tmpdir, name)
  cosmo.Barf(filepath, content)
  return filepath
end

-- Test basic Lua formatting
local function test_format_basic_lua()
  local input = write_temp("basic.lua", [[
local function hello(  x,y  )
  if x > 0  then
    print("positive")
      print("value:", x)
  elseif x < 0 then
        print("negative")
  else
    print("zero")
  end
  return x +   y
end
]])

  local ok, out = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok, "cosmic --format should succeed")
  local output = out as string
  -- Should normalize spacing
  assert(output:find("local function hello(x, y)", 1, true),
    "should normalize function args spacing, got: " .. output)
  -- Should not have space before ( in function calls
  assert(output:find('print("positive")', 1, true),
    "should not have space before ( in function calls, got: " .. output)
  -- Should preserve elseif/else structure
  assert(output:find("elseif x < 0 then", 1, true),
    "should preserve elseif, got: " .. output)
  assert(output:find("else\n", 1, true),
    "should preserve else, got: " .. output)
end
test_format_basic_lua()

-- Test formatting of file with syntax error
local function test_format_syntax_error()
  local input = write_temp("syntax_error.lua", [[
if if if
]])

  local ok, _out = spawn.spawn({cosmic, "--format", input}):read()
  assert(not ok, "cosmic --format should fail on syntax error")
end
test_format_syntax_error()

-- Test formatting Teal file with records
local function test_format_teal_record()
  local input = write_temp("record.tl", [[
local record Point
  x: number
  y: number
end

local function dist(p: Point): number
  return p.x + p.y
end
]])

  local ok, out = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok, "cosmic --format should succeed with records")
  local output = out as string
  -- Record body should be indented
  assert(output:find("  x: number", 1, true),
    "record fields should be indented, got: " .. output)
  -- end should be at top level
  assert(output:find("\nend\n", 1, true),
    "end should be at top level, got: " .. output)
end
test_format_teal_record()

-- Test idempotence: formatting formatted output should produce identical output
local function test_format_idempotent()
  local input = write_temp("idempotent.lua", [[
local function foo(x, y)
  if x then
    return y
  else
    return x
  end
end

local t = {1, 2, 3}
]])

  local ok1, out1 = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok1, "first format should succeed")

  -- Write first output and format again
  local second = write_temp("idempotent2.lua", out1 as string)
  local ok2, out2 = spawn.spawn({cosmic, "--format", second}):read()
  assert(ok2, "second format should succeed")

  assert(out1 == out2, "formatting should be idempotent:\nfirst:\n" .. (out1 as string) .. "\nsecond:\n" .. (out2 as string))
end
test_format_idempotent()

-- Test comment preservation
local function test_format_comments()
  local input = write_temp("comments.lua", [[
-- This is a header comment
local x = 1 -- inline comment

-- Block of code
local function foo()
  -- inside function
  return x
end
]])

  local ok, out = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok, "cosmic --format should succeed")
  local output = out as string
  assert(output:find("-- This is a header comment", 1, true),
    "should preserve header comment, got: " .. output)
  assert(output:find("-- inline comment", 1, true),
    "should preserve inline comment, got: " .. output)
  assert(output:find("-- inside function", 1, true),
    "should preserve inside comment, got: " .. output)
end
test_format_comments()

-- Test same-line brace pairs don't cause indent drift
local function test_format_inline_table()
  local input = write_temp("inline_table.lua", [[
local t = {a = 1, b = 2}
local x = 42
]])

  local ok, out = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok, "cosmic --format should succeed")
  local output = out as string
  -- x should be at indent level 0, not indented
  assert(output:find("\nlocal x = 42\n", 1, true),
    "same-line {} should not cause indent drift, got: " .. output)
end
test_format_inline_table()

-- Test missing input file
local function test_format_missing_file()
  local ok, _out = spawn.spawn({cosmic, "--format", "/nonexistent/file.lua"}):read()
  assert(not ok, "cosmic --format should fail on missing file")
end
test_format_missing_file()

-- Test shebang preservation
local function test_format_preserves_shebang()
  local input = write_temp("shebang.lua", "#!/usr/bin/env cosmic\nlocal x = 42\nprint(x)\n")

  local ok, out = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok, "cosmic --format should succeed")
  local output = out as string
  assert(output:sub(1, 21) == "#!/usr/bin/env cosmic",
    "shebang should be preserved at start of output, got: " .. output)
end
test_format_preserves_shebang()

-- Test blank line preservation (at most 1 blank line between sections)
local function test_format_blank_lines()
  local input = write_temp("blanks.lua", [[
local x = 1



local y = 2
]])

  local ok, out = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok, "cosmic --format should succeed")
  local output = out as string
  -- Should collapse multiple blank lines to at most 1
  assert(not output:find("\n\n\n", 1, true),
    "should collapse multiple blank lines, got: " .. output)
  -- But should preserve at least one blank line
  assert(output:find("\n\nlocal y", 1, true),
    "should preserve one blank line, got: " .. output)
end
test_format_blank_lines()

-- Test nested indentation
local function test_format_nested_indent()
  local input = write_temp("nested.lua", [[
local function foo()
if true then
if false then
return 1
end
end
end
]])

  local ok, out = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok, "cosmic --format should succeed")
  local output = out as string
  -- Check proper nesting
  assert(output:find("  if true then\n", 1, true),
    "first if should be indented 1 level, got: " .. output)
  assert(output:find("    if false then\n", 1, true),
    "nested if should be indented 2 levels, got: " .. output)
  assert(output:find("      return 1\n", 1, true),
    "return should be indented 3 levels, got: " .. output)
end
test_format_nested_indent()

-- Test function call spacing (no space before parens)
local function test_format_function_call_spacing()
  local input = write_temp("calls.lua", [[
print  ("hello")
local x = math.sqrt  (4)
foo  ()
]])

  local ok, out = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok, "cosmic --format should succeed")
  local output = out as string
  assert(output:find('print("hello")', 1, true),
    "should remove space before ( in print call, got: " .. output)
  assert(output:find("math.sqrt(4)", 1, true),
    "should remove space before ( in method call, got: " .. output)
  assert(output:find("foo()", 1, true),
    "should remove space before ( in foo call, got: " .. output)
end
test_format_function_call_spacing()

-- Test Teal file detection
local function test_format_teal_syntax()
  local input = write_temp("teal_syntax.tl", [[
local record Pair
  first: string
  second: integer
end

local function make(a: string, b: integer): Pair
  return {first = a, second = b}
end
]])

  local ok, out = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok, "cosmic --format should succeed on Teal file")
  local output = out as string
  -- Should preserve type annotations
  assert(output:find("first: string", 1, true),
    "should preserve type annotations, got: " .. output)
  assert(output:find("a: string", 1, true),
    "should preserve param type annotations, got: " .. output)
end
test_format_teal_syntax()

-- Test multi-line table
local function test_format_multiline_table()
  local input = write_temp("multitable.lua", [[
local t = {
  a = 1,
  b = 2,
  c = 3,
}
local after = true
]])

  local ok, out = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok, "cosmic --format should succeed")
  local output = out as string
  -- Items inside should be indented
  assert(output:find("  a = 1,\n", 1, true),
    "table items should be indented, got: " .. output)
  -- Closing brace at same level as opening
  assert(output:find("\n}\n", 1, true),
    "closing } should be at base indent, got: " .. output)
  -- After should not be indented
  assert(output:find("\nlocal after = true\n", 1, true),
    "code after table should not be indented, got: " .. output)
end
test_format_multiline_table()

-- Test repeat/until
local function test_format_repeat_until()
  local input = write_temp("repeat.lua", [[
repeat
x = x + 1
until x > 10
]])

  local ok, out = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok, "cosmic --format should succeed")
  local output = out as string
  assert(output:find("repeat\n  x = x + 1\nuntil", 1, true),
    "repeat/until should indent body, got: " .. output)
end
test_format_repeat_until()

-- Test that format of same input twice gives identical output (determinism)
local function test_format_deterministic()
  local input = write_temp("det.lua", [[
local function   messy(a,b  ,c)
  local   x=a+b
    local  y =  c
  return  x+y
end
]])

  local ok1, out1 = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok1, "first format should succeed")
  local ok2, out2 = spawn.spawn({cosmic, "--format", input}):read()
  assert(ok2, "second format should succeed")
  assert(out1 == out2, "formatting same input should always produce same output")
end
test_format_deterministic()

print("All format tests passed!")
