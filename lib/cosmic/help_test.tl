#!/usr/bin/env cosmic
-- test cosmic.help module

local help = require("cosmic.help")
local cli_args = require("cosmic.args")

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

local function test_generate_contains_all_longopts()
  local result = help.generate()
  assert(result:find("Cosmic options:"), "help text should contain 'Cosmic options:'")

  for _, opt in ipairs(cli_args.longopts) do
    local pattern = "%-%-" .. opt.name:gsub("%-", "%%-")
    assert(result:find(pattern), "help text missing long option: --" .. opt.name)
  end
end
test_generate_contains_all_longopts()

local function test_generate_contains_all_shortopts()
  local result = help.generate()
  assert(result:find("Standard lua options:") or result:find("Cosmic options:"),
    "help text should contain option sections")

  -- parse shortopts string, skipping ':' modifiers
  for c in cli_args.shortopts:gmatch("[^:]") do
    local pattern = "%-" .. c
    assert(result:find(pattern), "help text missing short option: -" .. c)
  end
end
test_generate_contains_all_shortopts()

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

local function test_generate_contains_guides_section()
  local result = help.generate()
  assert(result:find("Guides"), "help text should contain 'Guides'")
  assert(result:find("testing"), "help text should list testing guide")
  assert(result:find("formatting"), "help text should list formatting guide")
  assert(result:find("checking"), "help text should list checking guide")
end
test_generate_contains_guides_section()
