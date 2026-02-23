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

-- Test that ;; in TL_PATH expands to the default path (like LUA_PATH ;; semantics)
local function test_check_with_tl_path_double_semicolon()
  -- Write a custom type definition directory
  local typedir = path.join(tmpdir, "dstypes")
  local fs = require("cosmic.fs")
  fs.makedirs(typedir)
  local deffile = path.join(typedir, "dsmod.d.tl")
  local io_mod = require("cosmic.io")
  io_mod.barf(deffile, [[
local record dsmod
  value: function(): number
end
return dsmod
]])

  -- Write a file that uses both the custom type and a default cosmic module type
  local input = write_temp("ds_check.tl", [[
local dsmod = require("dsmod")
local n: number = dsmod.value()
local cosmo_check = require("cosmo")
print(n)
]])

  -- With TL_PATH=<custom>;;, the ;; expands to default paths, so both custom and default types resolve
  local base_env = unix.environ()
  local env_ds: {string} = {}
  for _, entry in ipairs(base_env) do
    if not entry:match("^TL_PATH=") then
      env_ds[#env_ds + 1] = entry
    end
  end
  -- Append ;; to include both the custom dir and the default path
  env_ds[#env_ds + 1] = "TL_PATH=" .. typedir .. "/?.d.tl;" .. typedir .. "/?/init.d.tl;;"
  local ok_ds, _ = spawn.spawn({cosmic, "--check-types", input}, {env = env_ds}):read()
  assert(ok_ds, "check should succeed with TL_PATH containing ;; expansion")

  -- Verify that without the ;; (custom only, no default), the cosmic module also resolves
  -- because TL_PATH without ;; is prepended to the default, so it still works
  local env_no_ds: {string} = {}
  for _, entry in ipairs(base_env) do
    if not entry:match("^TL_PATH=") then
      env_no_ds[#env_no_ds + 1] = entry
    end
  end
  env_no_ds[#env_no_ds + 1] = "TL_PATH=" .. typedir .. "/?.d.tl;" .. typedir .. "/?/init.d.tl"
  local ok_no_ds, _ = spawn.spawn({cosmic, "--check-types", input}, {env = env_no_ds}):read()
  assert(ok_no_ds, "check should also succeed with TL_PATH prepended (no ;; needed for default types)")
end
test_check_with_tl_path_double_semicolon()

print("All check tests passed!")
