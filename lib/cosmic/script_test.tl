#!/usr/bin/env cosmic
-- test cosmic script execution with .tl and .lua files

local path = require("cosmo.path")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")

local unix = require("cosmo.unix")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Create a unique subdirectory for this test run to avoid conflicts
local test_subdir = unix.mkdtemp(path.join(tmpdir, "cosmic_script_test_XXXXXX"))

local function write_temp(name: string, content: string): string
  local filepath = path.join(test_subdir, name)
  cosmo.Barf(filepath, content)

  -- Verify the file was written correctly
  local written = cosmo.Slurp(filepath)
  assert(written == content, "write_temp: file content mismatch for " .. name)

  return filepath
end

-- Test basic execution of .tl file
local function test_execute_teal_file()
  local script = write_temp("hello.tl", [[
local x: number = 42
print("answer=" .. x)
]]
  )

  local ok, out = spawn.spawn({cosmic, script}):read()
  assert(ok, "cosmic should execute .tl file")
  assert((out as string):find("answer=42"), "output should contain expected result")
end
test_execute_teal_file()

-- Test execution of .lua file (regression test)
local function test_execute_lua_file()
  local script = write_temp("hello.lua", [[
local x = 99
print("value=" .. x)
]]
  )

  local ok, out = spawn.spawn({cosmic, script}):read()
  assert(ok, "cosmic should execute .lua file")
  assert((out as string):find("value=99"), "output should contain expected result")
end
test_execute_lua_file()

-- Test .tl file with type error should fail gracefully
local function test_teal_type_error()
  local script = write_temp("type_error.tl", [[
local x: number = "wrong type"
print(x)
]]
  )

  -- stderr = 1 merges stderr into stdout so we can capture the error message
  local ok, out = spawn.spawn({cosmic, script}, {stderr = 1}):read()
  assert(not ok, "cosmic should fail on .tl file with type error")
  assert((out as string):find("type_error.tl"), "error should reference the file name")
end
test_teal_type_error()

-- Test .tl file with syntax error should fail gracefully
local function test_teal_syntax_error()
  local script = write_temp("syntax_error.tl", [[
if if if
]]
  )

  local ok, out = spawn.spawn({cosmic, script}):read()
  assert(not ok, "cosmic should fail on .tl file with syntax error")
end
test_teal_syntax_error()

-- Test .tl file with records
local function test_teal_with_records()
  local script = write_temp("records.tl", [[
local record Point
  x: number
  y: number
end

local p: Point = { x = 10, y = 20 }
print("point=" .. p.x .. "," .. p.y)
]]
  )

  local ok, out = spawn.spawn({cosmic, script}):read()
  assert(ok, "cosmic should execute .tl file with records")
  assert((out as string):find("point=10,20"), "output should contain expected result")
end
test_teal_with_records()

-- Test .tl file with generics
local function test_teal_with_generics()
  local script = write_temp("generics.tl", [[
local function identity<T>(x: T): T
  return x
end
print("result=" .. identity(123))
]]
  )

  local ok, out = spawn.spawn({cosmic, script}):read()
  assert(ok, "cosmic should execute .tl file with generics")
  assert((out as string):find("result=123"), "output should contain expected result")
end
test_teal_with_generics()

-- Test .tl file can require cosmic modules
local function test_teal_require_cosmic()
  local script = write_temp("require_cosmic.tl", [[
local cosmo = require("cosmo")
local data: string = cosmo.Slurp("/dev/null") or ""
print("bytes=" .. #data)
]]
  )

  local ok, out = spawn.spawn({cosmic, script}):read()
  assert(ok, "cosmic should execute .tl file with cosmic module requires")
  assert((out as string):find("bytes=0"), "output should contain expected result")
end
test_teal_require_cosmic()

-- Test script arguments are passed correctly to .tl files
local function test_teal_script_args()
  local script = write_temp("args.tl", [[
print("arg0=" .. arg[0])
print("arg1=" .. (arg[1] or "nil"))
print("arg2=" .. (arg[2] or "nil"))
]]
  )

  local ok, out = spawn.spawn({cosmic, script, "first", "second"}):read()
  assert(ok, "cosmic should execute .tl file with args")
  assert((out as string):find("arg0=" .. script), "arg[0] should be script path")
  assert((out as string):find("arg1=first"), "arg[1] should be first argument")
  assert((out as string):find("arg2=second"), "arg[2] should be second argument")
end
test_teal_script_args()

-- Test script arguments are passed correctly to .lua files (regression)
local function test_lua_script_args()
  local script = write_temp("args.lua", [[
print("arg0=" .. arg[0])
print("arg1=" .. (arg[1] or "nil"))
]]
  )

  local ok, out = spawn.spawn({cosmic, script, "test"}):read()
  assert(ok, "cosmic should execute .lua file with args")
  assert((out as string):find("arg0=" .. script), "arg[0] should be script path")
  assert((out as string):find("arg1=test"), "arg[1] should be argument")
end
test_lua_script_args()

-- Test .tl file with shebang
local function test_teal_with_shebang()
  local script = write_temp("shebang.tl", [[#!/usr/bin/env cosmic
local x: number = 777
print("shebang=" .. x)
]]
  )

  -- Verify the file exists and has correct content
  local verify = cosmo.Slurp(script)
  assert(verify:find("shebang="), "script file should contain shebang test code, got: " .. verify:sub(1, 100))

  local ok, out = spawn.spawn({cosmic, script}, {stderr = 1}):read()
  assert(ok, "cosmic should execute .tl file with shebang, got: " .. tostring(out))
  assert((out as string):find("shebang=777"), "output should contain expected result, got: " .. tostring(out))
end
test_teal_with_shebang()

print("All script tests passed!")
