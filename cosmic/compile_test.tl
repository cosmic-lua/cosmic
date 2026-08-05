#!/usr/bin/env cosmic
-- test cosmic --compile option

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local child = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  fs.write(filepath, content)
  return filepath
end

-- Test basic compilation of valid Teal file
local function test_compile_basic()
  local input = write_temp("basic.tl", [[
local x: number = 42
print(x)
]])

  local h1 = check.must(child.start({cosmic, "--compile", input}))
  local __r1 = check.must(h1:wait())
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "cosmic --compile should succeed")
  assert(not out:find(": number"), "output should not contain type annotations")
  assert(out:find("local x = 42"), "output should contain compiled Lua")
end
test_compile_basic()

-- Test compilation of file with syntax error
local function test_compile_syntax_error()
  local input = write_temp("syntax_error.tl", [[
if if if
]])

  local h2 = check.must(child.start({cosmic, "--compile", input}))
  local __r2 = check.must(h2:wait())
  local ok = __r2.ok
  assert(not ok, "cosmic --compile should fail on syntax error")
end
test_compile_syntax_error()

-- Test compilation of file with type error
local function test_compile_type_error()
  local input = write_temp("compile_type_error.tl", [[
local x: number = "wrong type"
]])

  local h3 = check.must(child.start({cosmic, "--compile", input}))
  local __r3 = check.must(h3:wait())
  local ok = __r3.ok
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

  local h4 = check.must(child.start({cosmic, "--compile", input}))
  local __r4 = check.must(h4:wait())
  local ok, out = __r4.ok, __r4.stdout
  assert(ok, "cosmic --compile should succeed with records")
  assert(out:find("local p = {"), "should compile record to table")
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

  local h5 = check.must(child.start({cosmic, "--compile", input}))
  local __r5 = check.must(h5:wait())
  local ok, out = __r5.ok, __r5.stdout
  assert(ok, "cosmic --compile should succeed with generics")
  assert(out:find("local function identity%(x%)"), "generics should be erased")
end
test_compile_generics()

-- Test missing input file
local function test_compile_missing_file()
  local h6 = check.must(child.start({cosmic, "--compile", "/nonexistent/file.tl"}))
  local __r6 = check.must(h6:wait())
  local ok = __r6.ok
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

  local h7 = check.must(child.start({cosmic, "--compile", input}))
  local __r7 = check.must(h7:wait())
  local ok, lua_code = __r7.ok, __r7.stdout
  assert(ok, "compilation should succeed")

  fs.write(output, lua_code)

  local h8 = check.must(child.start({cosmic, output}))
  local __r8 = check.must(h8:wait())
  local run_ok, run_out = __r8.ok, __r8.stdout
  assert(run_ok, "compiled output should run")
  assert(run_out:find("result=5"), "compiled code should produce correct output")
end
test_compiled_output_runs()

-- Test compile with cosmic module types
local function test_compile_with_cosmic_types()
  local input = write_temp("cosmic_types.tl", [[
local cosmo = require("cosmo")
local data: string = cosmo.Slurp("/dev/null") or ""
print("read " .. #data .. " bytes")
]])

  local h9 = check.must(child.start({cosmic, "--compile", input}))
  local __r9 = check.must(h9:wait())
  local ok = __r9.ok
  assert(ok, "compile with cosmic types should succeed")
end
test_compile_with_cosmic_types()

-- Test shebang preservation
local function test_compile_preserves_shebang()
  local input = write_temp("shebang.tl", [[#!/usr/bin/env cosmic
local x: number = 42
print(x)
]])

  local h10 = check.must(child.start({cosmic, "--compile", input}))
  local __r10 = check.must(h10:wait())
  local ok, out = __r10.ok, __r10.stdout
  assert(ok, "cosmic --compile should succeed")
  assert(out:sub(1, 21) == "#!/usr/bin/env cosmic", "shebang should be preserved at start of output")
  assert(out:find("\nlocal x = 42"), "compiled Lua should follow shebang")
end
test_compile_preserves_shebang()

-- Test file without shebang still works
local function test_compile_no_shebang()
  local input = write_temp("no_shebang.tl", [[local x: number = 42
print(x)
]])

  local h11 = check.must(child.start({cosmic, "--compile", input}))
  local __r11 = check.must(h11:wait())
  local ok, out = __r11.ok, __r11.stdout
  assert(ok, "cosmic --compile should succeed")
  assert(out:sub(1, 2) ~= "#!", "output should not have shebang if source didn't")
  assert(out:find("local x = 42"), "output should contain compiled Lua")
end
test_compile_no_shebang()

-- Test that compile uses lax mode (allows unknown variables)
local function test_compile_lax_mode()
  local input = write_temp("lax_mode.tl", [[
local function foo()
  return unknown_global_var
end
]])

  local h12 = check.must(child.start({cosmic, "--compile", input}))
  local __r12 = check.must(h12:wait())
  local ok, out = __r12.ok, __r12.stdout
  assert(ok, "compile should succeed in lax mode with unknown variables")
  assert(out:find("unknown_global_var"), "output should contain the unknown variable")
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
  local h13 = check.must(child.start({cosmic, "--write-if-changed", "--output", output, "--compile", input}))
  local __r13 = check.must(h13:wait())
  local ok1, _ = __r13.ok, __r13.stdout
  assert(ok1, "first compile --write-if-changed should succeed")

  local f1 = io.open(output, "r")
  assert(f1, "output file should exist after first run")
  local content1 = f1:read("*a")
  f1:close()
  assert(content1:find("local x = 42"), "output should contain compiled Lua")

  -- Record modification time
  local h14 = check.must(child.start({"stat", "-c", "%Y", output}))
  local __r14 = check.must(h14:wait())
  local mtime1_ok, mtime1 = __r14.ok, __r14.stdout
  assert(mtime1_ok, "stat should succeed")

  -- Small delay to ensure mtime would differ if file were rewritten
  os.execute("sleep 1")

  -- Second run: identical content, file should NOT be rewritten
  local h15 = check.must(child.start({cosmic, "--write-if-changed", "--output", output, "--compile", input}))
  local __r15 = check.must(h15:wait())
  local ok2, _ = __r15.ok, __r15.stdout
  assert(ok2, "second compile --write-if-changed should succeed")

  local h16 = check.must(child.start({"stat", "-c", "%Y", output}))
  local __r16 = check.must(h16:wait())
  local mtime2_ok, mtime2 = __r16.ok, __r16.stdout
  assert(mtime2_ok, "stat should succeed after second run")
  assert(mtime1 == mtime2, "file mtime should be unchanged when content identical: " .. tostring(mtime1) .. " vs " .. tostring(mtime2))
end
test_compile_write_if_changed()

-- Test write-if-changed with --format: skips write when formatted output is identical
local function test_format_write_if_changed()
  local input = write_temp("wic_fmt.lua", "local x = 42\n")
  local output = fs.join(tmpdir, "wic_fmt_out.lua")

  -- First run: output file does not exist, should be created
  local h17 = check.must(child.start({cosmic, "--write-if-changed", "--output", output, "--format", input}))
  local __r17 = check.must(h17:wait())
  local ok1, _ = __r17.ok, __r17.stdout
  assert(ok1, "first format --write-if-changed should succeed")

  local f1 = io.open(output, "r")
  assert(f1, "output file should exist after first format run")
  local content1 = f1:read("*a")
  f1:close()
  assert(content1:find("local x = 42"), "output should contain formatted Lua")

  -- Record modification time
  local h18 = check.must(child.start({"stat", "-c", "%Y", output}))
  local __r18 = check.must(h18:wait())
  local mtime1_ok, mtime1 = __r18.ok, __r18.stdout
  assert(mtime1_ok, "stat should succeed")

  -- Small delay to ensure mtime would differ if file were rewritten
  os.execute("sleep 1")

  -- Second run: identical content, file should NOT be rewritten
  local h19 = check.must(child.start({cosmic, "--write-if-changed", "--output", output, "--format", input}))
  local __r19 = check.must(h19:wait())
  local ok2, _ = __r19.ok, __r19.stdout
  assert(ok2, "second format --write-if-changed should succeed")

  local h20 = check.must(child.start({"stat", "-c", "%Y", output}))
  local __r20 = check.must(h20:wait())
  local mtime2_ok, mtime2 = __r20.ok, __r20.stdout
  assert(mtime2_ok, "stat should succeed after second format run")
  assert(mtime1 == mtime2, "file mtime should be unchanged when format output identical: " .. tostring(mtime1) .. " vs " .. tostring(mtime2))
end
test_format_write_if_changed()

-- --output/--write-if-changed are honored even AFTER --compile. The
-- dispatch used to return at --compile before reaching them, so a
-- trailing --output silently wrote to stdout instead of the file.
local function test_output_after_compile_reaches_the_file()
  local input = write_temp("after.tl", "local x: number = 7\nprint(x)\n")
  local out_path = fs.join(tmpdir, "after_out.lua")
  fs.unlink(out_path)
  local h = check.must(child.start({cosmic, "--compile", input,
        "--output", out_path, "--write-if-changed"}))
  local r = check.must(h:wait())
  assert(r.ok, "compile with a trailing --output should succeed: " ..
    (r.stderr or ""))
  assert(fs.is_file(out_path),
    "an --output after --compile must reach the file, not stdout")
  local written = check.must(fs.read(out_path))
  assert(written:find("local x = 7", 1, true), "got: " .. written)
end
test_output_after_compile_reaches_the_file()

print("All compile tests passed!")
