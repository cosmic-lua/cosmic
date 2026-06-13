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

-- Test that ;; in TL_PATH is treated as a placeholder for existing package.path
local function test_check_with_tl_path_double_semicolon()
  -- Write a type definition file in a custom directory
  local typedir = path.join(tmpdir, "mytypes2")
  unix.makedirs(typedir, 0x1ed) -- 0755
  local deffile = path.join(typedir, "mymod2.d.tl")
  cosmo.Barf(deffile, [[
local record mymod2
  hello: function(): string
end
return mymod2
]])

  -- Write a file that uses both the custom module and a built-in module
  local input = write_temp("tl_path_double_semicolon.tl", [[
local mymod2 = require("mymod2")
local s: string = mymod2.hello()
print(s)
]])

  -- Set TL_PATH with ;; before paths: custom_dir;;<existing paths would go here>
  local base_env = unix.environ()
  local env_with: {string} = {}
  for _, entry in ipairs(base_env) do
    if not entry:match("^TL_PATH=") then
      env_with[#env_with + 1] = entry
    end
  end
  -- ;; expands to existing package.path, so both custom module and built-ins resolve
  env_with[#env_with + 1] = "TL_PATH=" .. typedir .. "/?.d.tl;;" .. typedir .. "/?/init.d.tl"
  local ok_with, _ = spawn.spawn({cosmic, "--check-types", input}, {env = env_with}):read()
  assert(ok_with, "check should succeed with ;; in TL_PATH")
end
test_check_with_tl_path_double_semicolon()

-- Test that fix-hints appear for common Teal type-check traps.
-- We redirect stderr to stdout (opts.stderr=1) so the hint output is captured.

-- Hint 1: got number, expected integer
local function test_check_hint_number_integer()
  local input = write_temp("hint_num_int.tl", [[
local s = "hello"
local n: number = 3.14
local c = s:sub(n, n)
print(c)
]])
  local ok, out = spawn.spawn({cosmic, "--check-types", input}, {stderr = 1}):read()
  assert(not ok, "should fail with type error")
  assert(out:find("hint:"), "should include a hint, got: " .. out)
  assert(out:find("math%.tointeger"), "hint should mention math.tointeger, got: " .. out)
end
test_check_hint_number_integer()

-- Hint 2: ipairs on any type
local function test_check_hint_ipairs_any()
  local input = write_temp("hint_ipairs_any.tl", [[
local function get(): any
  return {1, 2, 3}
end
local arr = get()
for i, v in ipairs(arr) do
  print(i, v)
end
]])
  local ok, out = spawn.spawn({cosmic, "--check-types", input}, {stderr = 1}):read()
  assert(not ok, "should fail with type error")
  assert(out:find("hint:"), "should include a hint, got: " .. out)
  assert(out:find("as {any}"), "hint should mention casting to array, got: " .. out)
end
test_check_hint_ipairs_any()

-- Hint 3: excess return values
local function test_check_hint_excess_returns()
  local input = write_temp("hint_excess_rets.tl", [[
local function f(): string
  return "a", "b", "c"
end
f()
]])
  local ok, out = spawn.spawn({cosmic, "--check-types", input}, {stderr = 1}):read()
  assert(not ok, "should fail with type error")
  assert(out:find("hint:"), "should include a hint, got: " .. out)
  assert(out:find("local v, err"), "hint should mention capturing multiple returns, got: " .. out)
end
test_check_hint_excess_returns()

-- Hint 4: cannot use operator '..' for any type
local function test_check_hint_any_concat()
  local input = write_temp("hint_any_concat.tl", [[
local function get(): any
  return "hello"
end
local v = get()
local s = v .. " world"
print(s)
]])
  local ok, out = spawn.spawn({cosmic, "--check-types", input}, {stderr = 1}):read()
  assert(not ok, "should fail with type error")
  assert(out:find("hint:"), "should include a hint, got: " .. out)
  assert(out:find("cast first"), "hint should suggest casting, got: " .. out)
end
test_check_hint_any_concat()

-- Hint 5: cannot index any type
local function test_check_hint_any_index()
  local input = write_temp("hint_any_index.tl", [[
local function get(): any
  return {name = "world"}
end
local obj = get()
print(obj.name)
]])
  local ok, out = spawn.spawn({cosmic, "--check-types", input}, {stderr = 1}):read()
  assert(not ok, "should fail with type error")
  assert(out:find("hint:"), "should include a hint, got: " .. out)
  assert(out:find("cast first"), "hint should suggest casting, got: " .. out)
end
test_check_hint_any_index()

-- No duplicate hints per error
local function test_check_hint_no_duplicates()
  local input = write_temp("hint_no_dup.tl", [[
local s = "hello"
local n: number = 3.14
local c = s:sub(n, n)
print(c)
]])
  local ok, out = spawn.spawn({cosmic, "--check-types", input}, {stderr = 1}):read()
  assert(not ok, "should fail with type error")
  -- Count occurrences of "hint:"
  local count = 0
  for _ in out:gmatch("  hint:") do
    count = count + 1
  end
  assert(count == 1, "should have exactly one hint for one error, got " .. count .. " hints")
end
test_check_hint_no_duplicates()

print("All check tests passed!")
