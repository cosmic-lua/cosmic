#!/usr/bin/env cosmic
-- test --include-dir flag for --compile and --check types

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  fs.write(filepath, content)
  return filepath
end

-- Setup: create a custom type definition directory with a module
local function setup_custom_types(): string, string
  local typedir = fs.join(tmpdir, "customtypes")
  fs.makedirs(typedir, 0x1ed) -- 0755
  local deffile = fs.join(typedir, "custommod.d.tl")
  fs.write(deffile, [[
local record custommod
  greet: function(name: string): string
end
return custommod
]])
  return typedir, deffile
end

-- Test --include-dir with --compile
local function test_compile_include_dir()
  local typedir, _ = setup_custom_types()

  local input = write_temp("include_dir_compile.tl", [[
local custommod = require("custommod")
local s: string = custommod.greet("world")
print(s)
]])

  -- Without --include-dir, compilation should still succeed (lax mode)
  -- but with it, types are resolved properly
  local h1 = check.must(spawn.spawn({cosmic, "--include-dir", typedir, "--compile", input}))
  local __r1 = check.must(h1:wait())
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "compile with --include-dir should succeed: " .. tostring(out))
  assert(out:find("local custommod"), "output should contain compiled Lua")
end
test_compile_include_dir()

-- Test --include-dir with --check types
local function test_check_types_include_dir()
  local typedir, _ = setup_custom_types()

  local input = write_temp("include_dir_check.tl", [[
local custommod = require("custommod")
local s: string = custommod.greet("world")
print(s)
]])

  -- Without --include-dir, check should fail (strict mode, module not found)
  local h2 = check.must(spawn.spawn({cosmic, "--check", "types", input}))
  local __r2 = check.must(h2:wait())
  local ok_without, _ = __r2.ok, __r2.stdout
  assert(not ok_without, "check should fail without --include-dir for custom module")

  -- With --include-dir, check should succeed
  local h3 = check.must(spawn.spawn({cosmic, "--include-dir", typedir, "--check", "types", input}))
  local __r3 = check.must(h3:wait())
  local ok_with, out = __r3.ok, __r3.stdout
  assert(ok_with, "check with --include-dir should succeed: " .. tostring(out))
end
test_check_types_include_dir()

-- Test multiple --include-dir flags
local function test_multiple_include_dirs()
  local typedir1 = fs.join(tmpdir, "types1")
  fs.makedirs(typedir1, 0x1ed)
  fs.write(fs.join(typedir1, "mod_a.d.tl"), [[
local record mod_a
  hello: function(): string
end
return mod_a
]])

  local typedir2 = fs.join(tmpdir, "types2")
  fs.makedirs(typedir2, 0x1ed)
  fs.write(fs.join(typedir2, "mod_b.d.tl"), [[
local record mod_b
  world: function(): string
end
return mod_b
]])

  local input = write_temp("multi_include.tl", [[
local mod_a = require("mod_a")
local mod_b = require("mod_b")
print(mod_a.hello() .. mod_b.world())
]])

  local h = check.must(spawn.spawn({
        cosmic,
        "--include-dir", typedir1,
        "--include-dir", typedir2,
        "--check", "types", input,
      }))
  local __r4 = check.must(h:wait())
  local ok, out = __r4.ok, __r4.stdout
  assert(ok, "check with multiple --include-dir should succeed: " .. tostring(out))
end
test_multiple_include_dirs()

-- Test --include-dir combined with --write-if-changed and --output
local function test_compile_include_dir_with_output()
  local typedir, _ = setup_custom_types()
  local input = write_temp("include_dir_output.tl", [[
local custommod = require("custommod")
print(custommod.greet("test"))
]])
  local output = fs.join(tmpdir, "include_dir_output.lua")

  local h = check.must(spawn.spawn({
        cosmic, "--write-if-changed",
        "--output", output,
        "--include-dir", typedir,
        "--compile", input,
      }))
  local __r5 = check.must(h:wait())
  local ok, _ = __r5.ok, __r5.stdout
  assert(ok, "compile with --include-dir and --output should succeed")

  local f = io.open(output, "r")
  assert(f, "output file should exist")
  local content = f:read("*a")
  f:close()
  assert(content:find("local custommod"), "output should contain compiled Lua")
end
test_compile_include_dir_with_output()

-- Test that --include-dir merges with default include dirs
local function test_include_dir_merges_with_defaults()
  local typedir, _ = setup_custom_types()

  -- This file uses both a custom module and a built-in cosmic type
  local input = write_temp("merge_defaults.tl", [[
local custommod = require("custommod")
local fs = require("cosmic.fs")
local s: string = custommod.greet("world")
local p: string = fs.join("a", "b")
print(s, p)
]])

  local h4 = check.must(spawn.spawn({cosmic, "--include-dir", typedir, "--check", "types", input}))
  local __r6 = check.must(h4:wait())
  local ok, out = __r6.ok, __r6.stdout
  assert(ok, "check with --include-dir should still find built-in types: " .. tostring(out))
end
test_include_dir_merges_with_defaults()

print("All include-dir tests passed!")
