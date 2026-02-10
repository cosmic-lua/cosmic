#!/usr/bin/env cosmic
--- Tests for gentype.tl type definition generator.

local cosmo = require("cosmo")
local gentype = require("types.gentype")

-- Test type conversion from LuaLS to Teal
local function test_convert_type()
  -- Simple types
  assert(gentype.convert_type("string") == "string", "string type")
  assert(gentype.convert_type("integer") == "number", "integer -> number (Teal compat)")
  assert(gentype.convert_type("number") == "number", "number type")
  assert(gentype.convert_type("boolean") == "boolean", "boolean type")
  assert(gentype.convert_type("any") == "any", "any type")

  -- Alias types
  assert(gentype.convert_type("uint32") == "number", "uint32 -> number (Teal compat)")
  assert(gentype.convert_type("uint16") == "number", "uint16 -> number (Teal compat)")

  -- Array types
  assert(gentype.convert_type("string[]") == "{string}", "string[] -> {string}")
  assert(gentype.convert_type("integer[]") == "{number}", "integer[] -> {number}")

  -- Table types
  assert(gentype.convert_type("table<string,any>") == "{string:any}", "table<K,V> -> {K:V}")
  assert(gentype.convert_type("table<string, any>") == "{string:any}", "table<K, V> with space")

  -- Nullable types (optional marker stripped)
  assert(gentype.convert_type("string?") == "string", "string? -> string")
  assert(gentype.convert_type("integer?") == "number", "integer? -> number")

  -- Module-prefixed types
  assert(gentype.convert_type("lsqlite3.Database") == "Database", "lsqlite3.Database -> Database")
  assert(gentype.convert_type("unix.Errno") == "Errno", "unix.Errno -> Errno")

  print("test_convert_type: PASS")
end

-- Test module parsing
local function test_parse_path_module()
  local source = cosmo.Slurp("/zip/.lua/definitions.lua")
  assert(source, "Failed to read definitions.lua")

  local module = gentype.parse_module(source, "path")
  assert(module, "Failed to parse path module")
  assert(module.name == "path", "module name should be path")

  -- Check that functions were parsed
  assert(#module.functions > 0, "path should have functions")

  -- Look for specific functions
  local found_dirname = false
  local found_basename = false
  local found_join = false
  for _, f in ipairs(module.functions) do
    if f.name == "dirname" then found_dirname = true end
    if f.name == "basename" then found_basename = true end
    if f.name == "join" then found_join = true end
  end
  assert(found_dirname, "path.dirname should exist")
  assert(found_basename, "path.basename should exist")
  assert(found_join, "path.join should exist")

  print("test_parse_path_module: PASS")
end

-- Test unix module parsing (more complex with constants)
local function test_parse_unix_module()
  local source = cosmo.Slurp("/zip/.lua/definitions.lua")
  assert(source, "Failed to read definitions.lua")

  local module = gentype.parse_module(source, "unix")
  assert(module, "Failed to parse unix module")
  assert(module.name == "unix", "module name should be unix")

  -- Check that constants were parsed
  assert(#module.constants > 0, "unix should have constants, got " .. #module.constants)

  -- Look for specific constants
  local found_eacces = false
  local found_af_unix = false
  for _, c in ipairs(module.constants) do
    if c.name == "EACCES" then found_eacces = true end
    if c.name == "AF_UNIX" then found_af_unix = true end
  end
  assert(found_eacces, "unix.EACCES should exist")
  assert(found_af_unix, "unix.AF_UNIX should exist")

  print("test_parse_unix_module: PASS")
end

-- Test DTL generation
local function test_generate_dtl()
  local source = cosmo.Slurp("/zip/.lua/definitions.lua")
  assert(source, "Failed to read definitions.lua")

  local module = gentype.parse_module(source, "path")
  assert(module, "Failed to parse path module")

  local dtl = gentype.generate_dtl(module)
  assert(dtl, "Failed to generate DTL")

  -- Check for expected content
  assert(dtl:match("local record path"), "DTL should contain 'local record path'")
  assert(dtl:match("return path"), "DTL should contain 'return path'")
  assert(dtl:match("dirname: function"), "DTL should contain dirname function")

  print("test_generate_dtl: PASS")
end

-- Test run function
local function test_run()
  local result = gentype.run("path")
  assert(result.success, "run should succeed: " .. (result.error or ""))
  assert(result.output, "run should produce output")
  assert(result.output:match("local record path"), "output should contain path record")

  print("test_run: PASS")
end

-- Test getting module list
local function test_get_modules()
  local modules = gentype.get_modules()
  assert(#modules > 0, "should have modules")

  local found_unix = false
  local found_path = false
  for _, m in ipairs(modules) do
    if m == "unix" then found_unix = true end
    if m == "path" then found_path = true end
  end
  assert(found_unix, "modules should include unix")
  assert(found_path, "modules should include path")

  print("test_get_modules: PASS")
end

-- Normalize whitespace for comparison
local function normalize(s: string): string
  -- Remove trailing whitespace from lines
  s = s:gsub("[ \t]+\n", "\n")
  -- Normalize multiple newlines
  s = s:gsub("\n\n+", "\n\n")
  -- Remove trailing newline
  s = s:gsub("\n+$", "")
  return s
end

-- Drift detection test - verify generated matches committed file
local function test_drift_detection_path()
  local result = gentype.run("path")
  assert(result.success, "run should succeed for path")

  local committed = cosmo.Slurp("lib/types/cosmo/path.d.tl")
  if not committed then
    print("test_drift_detection_path: SKIP (no committed file)")
    return
  end

  -- For now, just check that we can generate something
  -- Full drift detection would require the generated output to match exactly
  assert(result.output:match("local record path"), "generated should have path record")
  print("test_drift_detection_path: PASS (basic check)")
end

-- Validate that hardcoded module list matches definitions.lua
local function test_module_list_completeness()
  local source = cosmo.Slurp("/zip/.lua/definitions.lua")
  assert(source, "Failed to read definitions.lua")

  -- Find all modules in definitions.lua by looking for lines like "modulename = {"
  -- Accept both "module = {" and "module={"
  -- Pattern must match module names with numbers (e.g., lsqlite3, argon2)
  local found_modules: {string} = {}
  for line in source:gmatch("[^\n]+") do
    local module_name = line:match("^([a-z0-9_]+)%s*=%s*%{")
    if module_name then
      table.insert(found_modules, module_name)
    end
  end

  -- Sort both lists for comparison
  table.sort(found_modules)

  local hardcoded = gentype.get_modules()
  local hardcoded_sorted: {string} = {}
  for _, m in ipairs(hardcoded) do
    table.insert(hardcoded_sorted, m)
  end
  table.sort(hardcoded_sorted)

  -- Modules in definitions.lua that we intentionally skip generating types for
  -- because no code in the codebase uses them
  local skip_modules: {string:boolean} = {
    ["finger"] = true,
    ["goodsocket"] = true,
    ["maxmind"] = true,
  }

  -- Check for missing modules (in definitions.lua but not in MODULES and not skipped)
  local missing: {string} = {}
  for _, m in ipairs(found_modules) do
    if skip_modules[m] then
      -- intentionally skipped
    else
      local found = false
      for _, h in ipairs(hardcoded_sorted) do
        if m == h then
          found = true
          break
        end
      end
      if not found then
        table.insert(missing, m)
      end
    end
  end

  -- Check for extra modules (in MODULES but not in definitions.lua)
  local extra: {string} = {}
  for _, h in ipairs(hardcoded_sorted) do
    local found = false
    for _, m in ipairs(found_modules) do
      if h == m then
        found = true
        break
      end
    end
    if not found then
      table.insert(extra, h)
    end
  end

  if #missing > 0 then
    local msg = "Missing modules in gentype.tl MODULES list: " .. table.concat(missing, ", ")
    msg = msg .. "\nUpdate lib/types/gentype.tl MODULES and cook.mk type_modules"
    error(msg)
  end

  if #extra > 0 then
    local msg = "Extra modules in gentype.tl MODULES list (not in definitions.lua): " .. table.concat(extra, ", ")
    error(msg)
  end

  print("test_module_list_completeness: PASS (found: " .. table.concat(found_modules, ", ") .. ")")
end

-- Run all tests
local function run_tests()
  test_convert_type()
  test_parse_path_module()
  test_parse_unix_module()
  test_generate_dtl()
  test_run()
  test_get_modules()
  test_module_list_completeness()
  test_drift_detection_path()

  print("\nAll tests passed!")
end

run_tests()
