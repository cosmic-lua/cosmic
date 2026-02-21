#!/usr/bin/env cosmic
-- test cosmic.help module

local help = require("cosmic.help")

local function test_generate_returns_string()
  local result = help.generate()
  assert(type(result) == "string", "generate() should return a string, got " .. type(result))
  assert(#result > 0, "generate() should return non-empty string")
end
test_generate_returns_string()

local function test_generate_contains_usage()
  local result = help.generate()
  assert(result:find("Usage:"), "help text should contain 'Usage:'")
end
test_generate_contains_usage()

local function test_generate_contains_cosmic_options()
  local result = help.generate()
  assert(result:find("Cosmic options:"), "help text should contain 'Cosmic options:'")
  
  local longopts: {string} = {
    "--help",
    "--compile",
    "--docs",
    "--format",
    "--check-format",
    "--check-types",
    "--embed",
    "--extract",
    "--benchmark",
    "--test",
    "--report",
    "--welcome",
    "--examples",
    "--check-examples",
  }
  
  for _, opt in ipairs(longopts) do
    local pattern = opt:gsub("%-", "%%-")
    assert(result:find(pattern), "help text missing long option: " .. opt)
  end
end
test_generate_contains_cosmic_options()

local function test_generate_contains_standard_lua_options()
  local result = help.generate()
  assert(result:find("Standard lua options:"), "help text should contain 'Standard lua options:'")
  
  local shortopts: {string} = {
    "-e",
    "-l",
    "-i",
    "-v",
    "-E",
    "-W",
  }
  
  for _, opt in ipairs(shortopts) do
    local pattern = opt:gsub("%-", "%%-")
    assert(result:find(pattern), "help text missing short option: " .. opt)
  end
end
test_generate_contains_standard_lua_options()

local function test_generate_contains_env_vars()
  local result = help.generate()
  assert(result:find("Environment variables:"), "help text should contain 'Environment variables:'")
  
  local env_vars: {string} = {
    "COSMIC_NO_REQUIRE_HINTS",
    "COSMIC_NO_WELCOME",
  }
  
  for _, var in ipairs(env_vars) do
    assert(result:find(var), "help text missing environment variable: " .. var)
  end
end
test_generate_contains_env_vars()

local function test_generate_contains_documentation_section()
  local result = help.generate()
  assert(result:find("Documentation:"), "help text should contain 'Documentation:'")
end
test_generate_contains_documentation_section()
