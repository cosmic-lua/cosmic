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
  assert(result:find("%-%-help"), "help text should contain '--help'")
  assert(result:find("%-%-compile"), "help text should contain '--compile'")
  assert(result:find("%-%-docs"), "help text should contain '--docs'")
  assert(result:find("%-%-format"), "help text should contain '--format'")
  assert(result:find("%-%-check%-format"), "help text should contain '--check-format'")
  assert(result:find("%-%-check%-types"), "help text should contain '--check-types'")
  assert(result:find("%-%-embed"), "help text should contain '--embed'")
  assert(result:find("%-%-extract"), "help text should contain '--extract'")
  assert(result:find("%-%-benchmark"), "help text should contain '--benchmark'")
  assert(result:find("%-%-test"), "help text should contain '--test'")
  assert(result:find("%-%-report"), "help text should contain '--report'")
  assert(result:find("%-%-welcome"), "help text should contain '--welcome'")
  assert(result:find("%-%-examples"), "help text should contain '--examples'")
  assert(result:find("%-%-check%-examples"), "help text should contain '--check-examples'")
end
test_generate_contains_cosmic_options()

local function test_generate_contains_standard_lua_options()
  local result = help.generate()
  assert(result:find("Standard lua options:"), "help text should contain 'Standard lua options:'")
  assert(result:find("%-e"), "help text should contain '-e'")
  assert(result:find("%-l"), "help text should contain '-l'")
  assert(result:find("%-i"), "help text should contain '-i'")
  assert(result:find("%-v"), "help text should contain '-v'")
  assert(result:find("%-E"), "help text should contain '-E'")
  assert(result:find("%-W"), "help text should contain '-W'")
end
test_generate_contains_standard_lua_options()

local function test_generate_contains_env_vars()
  local result = help.generate()
  assert(result:find("Environment variables:"), "help text should contain 'Environment variables:'")
  assert(result:find("COSMIC_NO_REQUIRE_HINTS"), "help text should mention COSMIC_NO_REQUIRE_HINTS")
  assert(result:find("COSMIC_NO_WELCOME"), "help text should mention COSMIC_NO_WELCOME")
end
test_generate_contains_env_vars()

local function test_generate_contains_documentation_section()
  local result = help.generate()
  assert(result:find("Documentation:"), "help text should contain 'Documentation:'")
end
test_generate_contains_documentation_section()
