#!/usr/bin/env cosmic
-- test cosmic script execution with .tl and .lua files

local fs = require("cosmic.fs")
local spawn = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Create a unique subdirectory for this test run to avoid conflicts
local test_subdir = fs.mkdtemp(fs.join(tmpdir, "cosmic_script_test_XXXXXX"))

local function write_temp(name: string, content: string): string
  local filepath = fs.join(test_subdir, name)
  fs.write(filepath, content)

  -- Verify the file was written correctly
  local written = fs.read(filepath)
  assert(written == content, "write_temp: file content mismatch for " .. name)

  return filepath
end

-- Test basic execution of .tl file
local function test_execute_teal_file()
  local script = write_temp("hello.tl", [[
local x: number = 42
print("answer=" .. x)
]])

  local h1 = spawn.spawn({cosmic, script})
  local __r1 = (h1 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "cosmic should execute .tl file")
  assert((out as string):find("answer=42"), "output should contain expected result")
end
test_execute_teal_file()

-- Test execution of .lua file (regression test)
local function test_execute_lua_file()
  local script = write_temp("hello.lua", [[
local x = 99
print("value=" .. x)
]])

  local h2 = spawn.spawn({cosmic, script})
  local __r2 = (h2 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r2.ok, __r2.stdout
  assert(ok, "cosmic should execute .lua file")
  assert((out as string):find("value=99"), "output should contain expected result")
end
test_execute_lua_file()

-- Test .tl file with type error should fail gracefully
local function test_teal_type_error()
  local script = write_temp("type_error.tl", [[
local x: number = "wrong type"
print(x)
]])

  -- the type-error diagnostic lands on stderr
  local h3 = spawn.spawn({cosmic, script})
  local __r3 = (h3 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r3.ok, __r3.stderr
  assert(not ok, "cosmic should fail on .tl file with type error")
  assert((out as string):find("type_error.tl"), "error should reference the file name")
end
test_teal_type_error()

-- Test .tl file with syntax error should fail gracefully
local function test_teal_syntax_error()
  local script = write_temp("syntax_error.tl", [[
if if if
]])

  local h4 = spawn.spawn({cosmic, script})
  local __r4 = (h4 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r4.ok, __r4.stdout
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
]])

  local h5 = spawn.spawn({cosmic, script})
  local __r5 = (h5 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r5.ok, __r5.stdout
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
]])

  local h6 = spawn.spawn({cosmic, script})
  local __r6 = (h6 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r6.ok, __r6.stdout
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
]])

  local h7 = spawn.spawn({cosmic, script})
  local __r7 = (h7 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r7.ok, __r7.stdout
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
]])

  local h8 = spawn.spawn({cosmic, script, "first", "second"})
  local __r8 = (h8 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r8.ok, __r8.stdout
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
]])

  local h9 = spawn.spawn({cosmic, script, "test"})
  local __r9 = (h9 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r9.ok, __r9.stdout
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
]])

  -- Verify the file exists and has correct content
  local verify = fs.read(script) as string
  assert(verify:find("shebang="), "script file should contain shebang test code, got: " .. verify:sub(1, 100))

  local h10 = spawn.spawn({cosmic, script})
  local __r10 = (h10 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r10.ok, __r10.stdout .. __r10.stderr
  assert(ok, "cosmic should execute .tl file with shebang, got: " .. tostring(out))
  assert((out as string):find("shebang=777"), "output should contain expected result, got: " .. tostring(out))
end
test_teal_with_shebang()

-- Test that running a .tl script twice reuses cosmic.script_cache's
-- compiled output (a cache hit), and that changing the script's content
-- (and so its mtime) invalidates the cache and picks up the new output.
local function test_script_cache_reuse_and_invalidation()
  local env = require("cosmic.env")
  env.set("COSMIC_TL_CACHE_DIR", fs.join(test_subdir, "tl-cache"), true)

  local script = write_temp("cached.tl", [[
local x: number = 1
print("value=" .. x)
]])

  for _ = 1, 2 do
    local h11 = spawn.spawn({cosmic, script})
    local __r11 = (h11 as spawn.Handle):wait() as spawn.Result
    local ok, out = __r11.ok, __r11.stdout
    assert(ok, "cosmic should execute .tl file: " .. tostring(out))
    assert((out as string):find("value=1"), "expected value=1, got: " .. tostring(out))
  end

  -- Overwrite with different content; the mtime change must invalidate
  -- the cached compiled output from the runs above.
  fs.write(script, [[
local x: number = 2
print("value=" .. x)
]])
  local h12 = spawn.spawn({cosmic, script})
  local __r12 = (h12 as spawn.Handle):wait() as spawn.Result
  local ok, out = __r12.ok, __r12.stdout
  assert(ok, "cosmic should execute changed .tl file: " .. tostring(out))
  assert((out as string):find("value=2"),
    "expected value=2 after script change (stale cache?), got: " .. tostring(out))
end
test_script_cache_reuse_and_invalidation()

print("All script tests passed!")
