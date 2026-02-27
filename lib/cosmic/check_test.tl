#!/usr/bin/env cosmic
-- test cosmic --check-types option

local path = require("cosmo.path")
local unix = require("cosmo.unix")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = path.join(tmpdir, name)
  cosmo.Barf(filepath, content)
  return filepath
end

-- Test check on valid Teal file
local function test_check_valid()
  local input = write_temp("valid.tl", [[
local x: number = 42
local y: string = "hello"
print(x, y)
]])

  local ok, out = spawn.spawn({cosmic, "--check-types", input}):read()
  assert(ok, "cosmic --check-types should succeed on valid file")
end
test_check_valid()

-- Test check detects type error
local function test_check_type_error()
  local input = write_temp("type_error.tl", [[
local x: number = "not a number"
]])

  local ok, out = spawn.spawn({cosmic, "--check-types", input}):read()
  assert(not ok, "cosmic --check-types should fail on type error")
end
test_check_type_error()

-- Test check on file with undefined variable
local function test_check_undefined_variable()
  local input = write_temp("undefined.tl", [[
local x: number = undefined_var
]])

  local ok, out = spawn.spawn({cosmic, "--check-types", input}):read()
  assert(not ok, "cosmic --check-types should fail on undefined variable")
end
test_check_undefined_variable()

-- Test check reports warnings (but succeeds)
local function test_check_warnings()
  local input = write_temp("warnings.tl", [[
local x: number = 42
-- x is unused, should generate warning but not fail
]])

  local ok, out = spawn.spawn({cosmic, "--check-types", input}):read()
  assert(ok, "cosmic --check-types should succeed with only warnings")
end
test_check_warnings()

-- Test check on missing file
local function test_check_missing_file()
  local ok, out = spawn.spawn({cosmic, "--check-types", "/nonexistent/file.tl"}):read()
  assert(not ok, "cosmic --check-types should fail on missing file")
end
test_check_missing_file()

-- Test check with cosmic module types
local function test_check_with_cosmic_types()
  local input = write_temp("cosmic_check.tl", [[
local cosmo = require("cosmo")
local path = require("cosmo.path")
local result: string = path.join("a", "b")
print(result)
]])

  local ok, out = spawn.spawn({cosmic, "--check-types", input}):read()
  assert(ok, "check with cosmic types should succeed")
end
test_check_with_cosmic_types()

-- Test that check uses strict mode (rejects unknown variables)
-- This same code compiles successfully in lax mode (see compile_test.tl)
local function test_check_strict_mode()
  local input = write_temp("strict_mode.tl", [[
local function foo()
  return unknown_global_var
end
]])

  local ok, _ = spawn.spawn({cosmic, "--check-types", input}):read()
  assert(not ok, "check should fail in strict mode with unknown variables")
end
test_check_strict_mode()

-- Test that TL_PATH env var is picked up by --check-types
local function test_check_with_tl_path()
  -- Write a type definition file in a custom directory
  local typedir = path.join(tmpdir, "mytypes")
  unix.makedirs(typedir, 0x1ed) -- 0755
  local deffile = path.join(typedir, "mymod.d.tl")
  cosmo.Barf(deffile, [[
local record mymod
  greet: function(name: string): string
end
return mymod
]])

  -- Write a file that uses the custom type
  local input = write_temp("tl_path_check.tl", [[
local mymod = require("mymod")
local s: string = mymod.greet("world")
print(s)
]])

  -- Without TL_PATH the type check should fail (module not found in default dirs)
  local ok_without, _ = spawn.spawn({cosmic, "--check-types", input}):read()
  assert(not ok_without, "check should fail without TL_PATH set for custom module")

  -- With TL_PATH pointing at the custom type dir it should succeed
  local base_env = unix.environ()
  local env_with: {string} = {}
  for _, entry in ipairs(base_env) do
    if not entry:match("^TL_PATH=") then
      env_with[#env_with + 1] = entry
    end
  end
  env_with[#env_with + 1] = "TL_PATH=" .. typedir .. "/?.d.tl;" .. typedir .. "/?/init.d.tl"
  local ok_with, _ = spawn.spawn({cosmic, "--check-types", input}, {env = env_with}):read()
  assert(ok_with, "check should succeed with TL_PATH set for custom module")
end
test_check_with_tl_path()

-- Test --write-if-changed with --output and --check-types: file created on first run
local function test_check_write_if_changed_creates_file()
  local input = write_temp("wic_check_basic.tl", [[
local x: number = 42
print(x)
]])
  local output = path.join(tmpdir, "wic_check_basic.out")

  local ok, _ = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--check-types", input}):read()
  assert(ok, "cosmic --write-if-changed --check-types should succeed")
  local content = cosmo.Slurp(output)
  assert(content and content:find("Type check passed"), "output file should contain type check status")
end
test_check_write_if_changed_creates_file()

-- Test --write-if-changed with --check-types: file timestamp preserved when content unchanged
local function test_check_write_if_changed_no_overwrite()
  local input = write_temp("wic_check_stable.tl", [[
local y: number = 99
print(y)
]])
  local output = path.join(tmpdir, "wic_check_stable.out")

  -- First run: create the file
  local ok1, _ = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--check-types", input}):read()
  assert(ok1, "first check should succeed")

  -- Record mtime after first run
  local stat1 = unix.stat(output)
  assert(stat1, "output file should exist after first run")
  local mtime1, mtime1ns = stat1:mtim()

  -- Second run: content is identical, file should not be rewritten
  local ok2, _ = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--check-types", input}):read()
  assert(ok2, "second check should succeed")

  local stat2 = unix.stat(output)
  assert(stat2, "output file should still exist after second run")
  local mtime2, mtime2ns = stat2:mtim()

  assert(mtime1 == mtime2 and mtime1ns == mtime2ns, "mtime should be unchanged when content is identical")
end
test_check_write_if_changed_no_overwrite()

print("All check tests passed!")
