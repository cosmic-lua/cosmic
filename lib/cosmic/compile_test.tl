#!/usr/bin/env cosmic
-- test cosmic --compile option

local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local cio = require("cosmic.io")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  cio.barf(filepath, content)
  return filepath
end

-- Test basic compilation of valid Teal file
local function test_compile_basic()
  local input = write_temp("basic.tl", [[
local x: number = 42
print(x)
]])

  local h1 = spawn.spawn({cosmic, "--compile", input})
  local ok, out = (h1 as spawn.Handle):read()
  assert(ok, "cosmic --compile should succeed")
  assert(not (out as string):find(": number"), "output should not contain type annotations")
  assert((out as string):find("local x = 42"), "output should contain compiled Lua")
end
test_compile_basic()

-- Test compilation of file with syntax error
local function test_compile_syntax_error()
  local input = write_temp("syntax_error.tl", [[
if if if
]])

  local h2 = spawn.spawn({cosmic, "--compile", input})
  local ok, out = (h2 as spawn.Handle):read()
  assert(not ok, "cosmic --compile should fail on syntax error")
end
test_compile_syntax_error()

-- Test compilation of file with type error
local function test_compile_type_error()
  local input = write_temp("compile_type_error.tl", [[
local x: number = "wrong type"
]])

  local h3 = spawn.spawn({cosmic, "--compile", input})
  local ok, out = (h3 as spawn.Handle):read()
  assert(not ok, "cosmic --compile should fail on type error")
end
test_compile_type_error()

-- Test compilation with records
local function test_compile_record()
  local input = write_temp("record.tl", [[
local record Point
  x: number
  y: number
end

local p: Point = { x = 10, y = 20 }
print(p.x, p.y)
]])

  local h4 = spawn.spawn({cosmic, "--compile", input})
  local ok, out = (h4 as spawn.Handle):read()
  assert(ok, "cosmic --compile should succeed with records")
  assert((out as string):find("local p = {"), "should compile record to table")
end
test_compile_record()

-- Test compilation with generics
local function test_compile_generics()
  local input = write_temp("generics.tl", [[
local function identity<T>(x: T): T
  return x
end
print(identity(42))
]])

  local h5 = spawn.spawn({cosmic, "--compile", input})
  local ok, out = (h5 as spawn.Handle):read()
  assert(ok, "cosmic --compile should succeed with generics")
  assert((out as string):find("local function identity%(x%)"), "generics should be erased")
end
test_compile_generics()

-- Test missing input file
local function test_compile_missing_file()
  local h6 = spawn.spawn({cosmic, "--compile", "/nonexistent/file.tl"})
  local ok, out = (h6 as spawn.Handle):read()
  assert(not ok, "cosmic --compile should fail on missing file")
end
test_compile_missing_file()

-- Test that compiled output is executable
local function test_compiled_output_runs()
  local input = write_temp("runnable.tl", [[
local function add(a: number, b: number): number
  return a + b
end
print("result=" .. add(2, 3))
]])
  local output = fs.join(tmpdir, "runnable.lua")

  local h7 = spawn.spawn({cosmic, "--compile", input})
  local ok, lua_code = (h7 as spawn.Handle):read()
  assert(ok, "compilation should succeed")

  cio.barf(output, lua_code as string)

  local h8 = spawn.spawn({cosmic, output})
  local run_ok, run_out = (h8 as spawn.Handle):read()
  assert(run_ok, "compiled output should run")
  assert((run_out as string):find("result=5"), "compiled code should produce correct output")
end
test_compiled_output_runs()

-- Test compile with cosmic module types
local function test_compile_with_cosmic_types()
  local input = write_temp("cosmic_types.tl", [[
local cosmo = require("cosmo")
local data: string = cosmo.Slurp("/dev/null") or ""
print("read " .. #data .. " bytes")
]])

  local h9 = spawn.spawn({cosmic, "--compile", input})
  local ok, out = (h9 as spawn.Handle):read()
  assert(ok, "compile with cosmic types should succeed")
end
test_compile_with_cosmic_types()

-- Test shebang preservation
local function test_compile_preserves_shebang()
  local input = write_temp("shebang.tl", [[#!/usr/bin/env cosmic
local x: number = 42
print(x)
]])

  local h10 = spawn.spawn({cosmic, "--compile", input})
  local ok, out = (h10 as spawn.Handle):read()
  assert(ok, "cosmic --compile should succeed")
  assert((out as string):sub(1, 21) == "#!/usr/bin/env cosmic", "shebang should be preserved at start of output")
  assert((out as string):find("\nlocal x = 42"), "compiled Lua should follow shebang")
end
test_compile_preserves_shebang()

-- Test file without shebang still works
local function test_compile_no_shebang()
  local input = write_temp("no_shebang.tl", [[local x: number = 42
print(x)
]])

  local h11 = spawn.spawn({cosmic, "--compile", input})
  local ok, out = (h11 as spawn.Handle):read()
  assert(ok, "cosmic --compile should succeed")
  assert((out as string):sub(1, 2) ~= "#!", "output should not have shebang if source didn't")
  assert((out as string):find("local x = 42"), "output should contain compiled Lua")
end
test_compile_no_shebang()

-- Test that compile uses lax mode (allows unknown variables)
local function test_compile_lax_mode()
  local input = write_temp("lax_mode.tl", [[
local function foo()
  return unknown_global_var
end
]])

  local h12 = spawn.spawn({cosmic, "--compile", input})
  local ok, out = (h12 as spawn.Handle):read()
  assert(ok, "compile should succeed in lax mode with unknown variables")
  assert((out as string):find("unknown_global_var"), "output should contain the unknown variable")
end
test_compile_lax_mode()

-- Test write-if-changed: creates file on first run, skips write on second run
local function test_compile_write_if_changed()
  local input = write_temp("wic.tl", [[
local x: number = 42
print(x)
]])
  local output = fs.join(tmpdir, "wic.lua")

  -- First run: file does not exist, should be created
  local h13 = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--compile", input})
  local ok1, _ = (h13 as spawn.Handle):read()
  assert(ok1, "first compile --write-if-changed should succeed")

  local f1 = io.open(output, "r")
  assert(f1, "output file should exist after first run")
  local content1 = f1:read("*a")
  f1:close()
  assert(content1:find("local x = 42"), "output should contain compiled Lua")

  -- Record modification time
  local h14 = spawn.spawn({"stat", "-c", "%Y", output})
  local mtime1_ok, mtime1 = (h14 as spawn.Handle):read()
  assert(mtime1_ok, "stat should succeed")

  -- Small delay to ensure mtime would differ if file were rewritten
  os.execute("sleep 1")

  -- Second run: identical content, file should NOT be rewritten
  local h15 = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--compile", input})
  local ok2, _ = (h15 as spawn.Handle):read()
  assert(ok2, "second compile --write-if-changed should succeed")

  local h16 = spawn.spawn({"stat", "-c", "%Y", output})
  local mtime2_ok, mtime2 = (h16 as spawn.Handle):read()
  assert(mtime2_ok, "stat should succeed after second run")
  assert(mtime1 == mtime2, "file mtime should be unchanged when content identical: " .. tostring(mtime1) .. " vs " .. tostring(mtime2))
end
test_compile_write_if_changed()

-- Test write-if-changed with --format: skips write when formatted output is identical
local function test_format_write_if_changed()
  local input = write_temp("wic_fmt.lua", "local x = 42\n")
  local output = fs.join(tmpdir, "wic_fmt_out.lua")

  -- First run: output file does not exist, should be created
  local h17 = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--format", input})
  local ok1, _ = (h17 as spawn.Handle):read()
  assert(ok1, "first format --write-if-changed should succeed")

  local f1 = io.open(output, "r")
  assert(f1, "output file should exist after first format run")
  local content1 = f1:read("*a")
  f1:close()
  assert(content1:find("local x = 42"), "output should contain formatted Lua")

  -- Record modification time
  local h18 = spawn.spawn({"stat", "-c", "%Y", output})
  local mtime1_ok, mtime1 = (h18 as spawn.Handle):read()
  assert(mtime1_ok, "stat should succeed")

  -- Small delay to ensure mtime would differ if file were rewritten
  os.execute("sleep 1")

  -- Second run: identical content, file should NOT be rewritten
  local h19 = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--format", input})
  local ok2, _ = (h19 as spawn.Handle):read()
  assert(ok2, "second format --write-if-changed should succeed")

  local h20 = spawn.spawn({"stat", "-c", "%Y", output})
  local mtime2_ok, mtime2 = (h20 as spawn.Handle):read()
  assert(mtime2_ok, "stat should succeed after second format run")
  assert(mtime1 == mtime2, "file mtime should be unchanged when format output identical: " .. tostring(mtime1) .. " vs " .. tostring(mtime2))
end
test_format_write_if_changed()

print("All compile tests passed!")
