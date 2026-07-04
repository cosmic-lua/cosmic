#!/usr/bin/env cosmic
-- test cosmic script argument passing (varargs and arg table)

local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local cio = require("cosmic.io")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Test script that uses only varargs (...)
local function test_varargs_only()
  local script = fs.join(tmpdir, "varargs.lua") as string
  cio.barf(script, [[
local args = {...}
print("varargs_count=" .. #args)
for i, v in ipairs(args) do
  print("vararg[" .. i .. "]=" .. tostring(v))
end
]])

  local ok, out = spawn.spawn({cosmic, script, "foo", "bar", "baz"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("varargs_count=3"), "should have 3 varargs")
  assert((out as string):find("vararg%[1%]=foo"), "vararg[1] should be foo")
  assert((out as string):find("vararg%[2%]=bar"), "vararg[2] should be bar")
  assert((out as string):find("vararg%[3%]=baz"), "vararg[3] should be baz")
end
test_varargs_only()

-- Test script that uses only global arg table
local function test_arg_table_only()
  local script = fs.join(tmpdir, "argtable.lua") as string
  cio.barf(script, [[
print("arg_count=" .. #arg)
print("arg[0]=" .. tostring(arg[0]))
for i = 1, #arg do
  print("arg[" .. i .. "]=" .. tostring(arg[i]))
end
]])

  local ok, out = spawn.spawn({cosmic, script, "alpha", "beta"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("arg_count=2"), "should have 2 args")
  assert((out as string):find("arg%[0%]=" .. script:gsub("[%-%.]", "%%%1")), "arg[0] should be script path")
  assert((out as string):find("arg%[1%]=alpha"), "arg[1] should be alpha")
  assert((out as string):find("arg%[2%]=beta"), "arg[2] should be beta")
end
test_arg_table_only()

-- Test that both varargs and arg table work together and match
local function test_varargs_and_arg_table()
  local script = fs.join(tmpdir, "both.lua") as string
  cio.barf(script, [[
local varargs = {...}
print("varargs_count=" .. #varargs)
print("arg_count=" .. #arg)
print("match=" .. tostring(#varargs == #arg))
for i = 1, #arg do
  print("match[" .. i .. "]=" .. tostring(arg[i] == varargs[i]))
end
]])

  local ok, out = spawn.spawn({cosmic, script, "x", "y", "z"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("varargs_count=3"), "varargs should have 3 elements")
  assert((out as string):find("arg_count=3"), "arg should have 3 elements")
  assert((out as string):find("match=true"), "varargs and arg counts should match")
  assert((out as string):find("match%[1%]=true"), "arg[1] should match varargs[1]")
  assert((out as string):find("match%[2%]=true"), "arg[2] should match varargs[2]")
  assert((out as string):find("match%[3%]=true"), "arg[3] should match varargs[3]")
end
test_varargs_and_arg_table()

-- Test the common pattern: function main(...) os.exit(main(...))
local function test_main_function_with_varargs()
  local script = fs.join(tmpdir, "main_varargs.lua")
  cio.barf(script, [[
local function main(...)
  local args = {...}
  print("main_varargs_count=" .. #args)
  for i, v in ipairs(args) do
    print("main_arg[" .. i .. "]=" .. tostring(v))
  end
  return 0
end

os.exit(main(...))
]])

  local ok, out = spawn.spawn({cosmic, script, "one", "two"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("main_varargs_count=2"), "main should receive 2 varargs")
  assert((out as string):find("main_arg%[1%]=one"), "main_arg[1] should be one")
  assert((out as string):find("main_arg%[2%]=two"), "main_arg[2] should be two")
end
test_main_function_with_varargs()

-- Test function main(param) with single optional parameter
local function test_main_function_with_single_param()
  local script = fs.join(tmpdir, "main_param.lua")
  cio.barf(script, [[
local function main(dir)
  dir = dir or "default"
  print("param=" .. dir)
  return 0
end

os.exit(main(...))
]])

  -- Test with argument
  local ok, out = spawn.spawn({cosmic, script, "custom"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("param=custom"), "param should be custom")

  -- Test with no argument (should use default)
  ok, out = spawn.spawn({cosmic, script}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("param=default"), "param should be default")
end
test_main_function_with_single_param()

-- Test script with no arguments
local function test_no_arguments()
  local script = fs.join(tmpdir, "noargs.lua")
  cio.barf(script, [[
local args = {...}
print("varargs_count=" .. #args)
print("arg_count=" .. #arg)
print("arg[0]=" .. tostring(arg[0]))
]])

  local ok, out = spawn.spawn({cosmic, script}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("varargs_count=0"), "varargs should be empty")
  assert((out as string):find("arg_count=0"), "arg should be empty")
  assert((out as string):find("arg%[0%]="), "arg[0] should be set")
end
test_no_arguments()

-- Test arguments containing spaces
local function test_arguments_with_spaces()
  local script = fs.join(tmpdir, "spaces.lua")
  cio.barf(script, [[
local args = {...}
for i, v in ipairs(args) do
  print("arg[" .. i .. "]=" .. v)
end
]])

  local ok, out = spawn.spawn({cosmic, script, "hello world", "foo bar"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("arg%[1%]=hello world"), "should preserve spaces in arg[1]")
  assert((out as string):find("arg%[2%]=foo bar"), "should preserve spaces in arg[2]")
end
test_arguments_with_spaces()

-- Test arguments with special characters (use -- to separate from cosmic options)
local function test_arguments_with_special_chars()
  local script = fs.join(tmpdir, "special.lua")
  cio.barf(script, [[
local args = {...}
for i, v in ipairs(args) do
  print("arg[" .. i .. "]=" .. v)
end
]])

  local ok, out = spawn.spawn({cosmic, script, "--", "--flag", "-x", "value=123"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("arg%[1%]=%-%-flag"), "should handle --flag")
  assert((out as string):find("arg%[2%]=%-x"), "should handle -x")
  assert((out as string):find("arg%[3%]=value=123"), "should handle value=123")
end
test_arguments_with_special_chars()

-- Test that cosmo.is_main() still works with new varargs approach
local function test_cosmo_is_main_compatibility()
  local script = fs.join(tmpdir, "is_main.lua")
  cio.barf(script, [[
local proc = require("cosmic.proc")

local function main(...)
  local args = {...}
  print("main_called=true")
  print("args_count=" .. #args)
  return 0
end

if proc.is_main() then
  os.exit(main(...))
end
]])

  local ok, out = spawn.spawn({cosmic, script, "test1", "test2"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("main_called=true"), "main should be called")
  assert((out as string):find("args_count=2"), "main should receive 2 args")
end
test_cosmo_is_main_compatibility()

-- Test that --version after script name is passed to script (not consumed by cosmic)
local function test_version_flag_after_script()
  local script = fs.join(tmpdir, "version_arg.lua")
  cio.barf(script, [[
local args = {...}
print("args_count=" .. #arg)
for i, v in ipairs(args) do
  print("arg[" .. i .. "]=" .. v)
end
]])

  local ok, out = spawn.spawn({cosmic, script, "--version"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("args_count=1"), "should have 1 arg")
  assert((out as string):find("arg%[1%]=%-%-version"), "arg[1] should be --version")
end
test_version_flag_after_script()

-- Test that --help after script name is passed to script (not consumed by cosmic)
local function test_help_flag_after_script()
  local script = fs.join(tmpdir, "help_arg.lua")
  cio.barf(script, [[
local args = {...}
print("args_count=" .. #arg)
for i, v in ipairs(args) do
  print("arg[" .. i .. "]=" .. v)
end
]])

  local ok, out = spawn.spawn({cosmic, script, "--help"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("args_count=1"), "should have 1 arg")
  assert((out as string):find("arg%[1%]=%-%-help"), "arg[1] should be --help")
end
test_help_flag_after_script()

-- Test that -v after script name is passed to script (not consumed by cosmic)
local function test_v_flag_after_script()
  local script = fs.join(tmpdir, "v_arg.lua")
  cio.barf(script, [[
local args = {...}
print("args_count=" .. #arg)
for i, v in ipairs(args) do
  print("arg[" .. i .. "]=" .. v)
end
]])

  local ok, out = spawn.spawn({cosmic, script, "-v"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("args_count=1"), "should have 1 arg")
  assert((out as string):find("arg%[1%]=%-v"), "arg[1] should be -v")
end
test_v_flag_after_script()

-- Test cosmic options before script and script options after
local function test_mixed_cosmic_and_script_options()
  local script = fs.join(tmpdir, "mixed.lua")
  cio.barf(script, [[
local args = {...}
print("args_count=" .. #arg)
for i, v in ipairs(args) do
  print("arg[" .. i .. "]=" .. v)
end
]])

  -- cosmic -e before script, then script gets --version
  local ok, out = spawn.spawn({cosmic, "-e", "print('cosmic executed')", script, "--version", "arg2"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("cosmic executed"), "cosmic -e should execute")
  assert((out as string):find("args_count=2"), "script should have 2 args")
  assert((out as string):find("arg%[1%]=%-%-version"), "arg[1] should be --version")
  assert((out as string):find("arg%[2%]=arg2"), "arg[2] should be arg2")
end
test_mixed_cosmic_and_script_options()

-- Test multiple option-like arguments after script name
local function test_multiple_option_like_args()
  local script = fs.join(tmpdir, "multi_opts.lua")
  cio.barf(script, [[
local args = {...}
print("args_count=" .. #arg)
for i, v in ipairs(args) do
  print("arg[" .. i .. "]=" .. v)
end
]])

  local ok, out = spawn.spawn({cosmic, script, "--version", "--help", "-v", "-i", "--unknown"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("args_count=5"), "should have 5 args")
  assert((out as string):find("arg%[1%]=%-%-version"), "arg[1] should be --version")
  assert((out as string):find("arg%[2%]=%-%-help"), "arg[2] should be --help")
  assert((out as string):find("arg%[3%]=%-v"), "arg[3] should be -v")
  assert((out as string):find("arg%[4%]=%-i"), "arg[4] should be -i")
  assert((out as string):find("arg%[5%]=%-%-unknown"), "arg[5] should be --unknown")
end
test_multiple_option_like_args()

-- Test that -- separator works without script options after it
local function test_separator_with_no_following_options()
  local script = fs.join(tmpdir, "separator_simple.lua")
  cio.barf(script, [[
local args = {...}
print("args_count=" .. #arg)
for i, v in ipairs(args) do
  print("arg[" .. i .. "]=" .. v)
end
]])

  local ok, out = spawn.spawn({cosmic, script, "--", "arg1", "arg2"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("args_count=2"), "should have 2 args")
  assert((out as string):find("arg%[1%]=arg1"), "arg[1] should be arg1")
  assert((out as string):find("arg%[2%]=arg2"), "arg[2] should be arg2")
  -- Ensure -- separator is not included in script args
  assert(not (out as string):find("arg%[%d+%]=%-%-$"), "-- should not be in script args")
end
test_separator_with_no_following_options()

-- Test real-world nvim-like case: script.lua --version
local function test_nvim_version_pattern()
  local script = fs.join(tmpdir, "nvim_like.lua")
  cio.barf(script, [[
-- Simulate nvim-like wrapper that checks for --version
for i = 1, #arg do
  if arg[i] == "--version" then
    print("NVIM v0.12.0-dev")
    os.exit(0)
  end
end
print("No --version flag found")
]])

  local ok, out = spawn.spawn({cosmic, script, "--version"}):read()
  assert(ok, "cosmic should succeed")
  assert((out as string):find("NVIM v0%.12%.0%-dev"), "script should handle --version")
  assert(not (out as string):find("No %-%-version flag found"), "should not print fallback message")
end
test_nvim_version_pattern()

-- Test that all CLI options appear in help text
local function test_help_includes_all_options()
  local cli = require("cosmic.args")

  -- Run cosmic --help and capture output
  local ok, out = spawn.spawn({cosmic, "--help"}):read()
  assert(ok, "cosmic --help should succeed")
  local help_text = out as string

  -- Extract short option characters from shortopts (skip ':' modifiers)
  local short_options: {string} = {}
  local i = 1
  while i <= #cli.shortopts do
    local c = cli.shortopts:sub(i, i)
    if c ~= ":" then
      table.insert(short_options, "-" .. c)
    end
    i = i + 1
  end

  -- Extract long option names from longopts table
  local long_options: {string} = {}
  for _, opt in ipairs(cli.longopts) do
    table.insert(long_options, "--" .. opt.name)
  end

  -- Check that every short option appears in help text
  for _, opt in ipairs(short_options) do
    local pattern = opt:gsub("%-", "%%-")
    assert(help_text:find(pattern), "help text missing short option: " .. opt)
  end

  -- Check that every long option appears in help text
  for _, opt in ipairs(long_options) do
    local pattern = opt:gsub("%-", "%%-")
    assert(help_text:find(pattern), "help text missing long option: " .. opt)
  end
end
test_help_includes_all_options()
