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

-- Test --check-types --output writes file
local function test_check_types_output_flag()
  local input = write_temp("check_output.tl", [[
local x: number = 42
print(x)
]])
  local output = path.join(tmpdir, "check_output.got")

  local ok, _ = spawn.spawn({cosmic, "--check-types", "--output", output, input}):read()
  assert(ok, "check-types with --output should succeed")
  local content = cosmo.Slurp(output)
  assert(content and content:find("Type check passed"), "output file should contain type check result")
end
test_check_types_output_flag()

-- Test --check-types --write-if-changed --output skips write when content unchanged
local function test_check_types_write_if_changed()
  local input = write_temp("check_wic.tl", [[
local y: string = "hello"
print(y)
]])
  local output = path.join(tmpdir, "check_wic.got")

  -- first run: file does not exist, must be written
  local ok1, _ = spawn.spawn({cosmic, "--check-types", "--write-if-changed", "--output", output, input}):read()
  assert(ok1, "first check-types --write-if-changed should succeed")
  local content1 = cosmo.Slurp(output)
  assert(content1 and content1:find("Type check passed"), "output file should contain result after first run")

  -- overwrite output with different content, then re-run
  cosmo.Barf(output, "-- sentinel\n")
  local ok2, _ = spawn.spawn({cosmic, "--check-types", "--write-if-changed", "--output", output, input}):read()
  assert(ok2, "second check-types --write-if-changed should succeed")
  local content2 = cosmo.Slurp(output)
  assert(content2 and content2:find("Type check passed"), "output file should be updated when content differs")

  -- run again with identical content: output should not change
  local content_before = cosmo.Slurp(output)
  local ok3, _ = spawn.spawn({cosmic, "--check-types", "--write-if-changed", "--output", output, input}):read()
  assert(ok3, "third check-types --write-if-changed should succeed")
  local content_after = cosmo.Slurp(output)
  assert(content_before == content_after, "output file should be unchanged when content identical")
end
test_check_types_write_if_changed()

print("All check tests passed!")
