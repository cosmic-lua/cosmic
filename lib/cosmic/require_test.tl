#!/usr/bin/env cosmic
--- Tests for enhanced require with helpful error messages.

local require_mod = require("cosmic.require")

local function test_module_exists_preloaded()
  -- cosmo modules are preloaded
  assert(require_mod.module_exists("cosmo.unix"), "cosmo.unix should exist")
  assert(require_mod.module_exists("cosmo.path"), "cosmo.path should exist")
  assert(require_mod.module_exists("cosmo.argon2"), "cosmo.argon2 should exist")
end
test_module_exists_preloaded()

local function test_module_exists_cosmic()
  -- cosmic modules are in package.path
  assert(require_mod.module_exists("cosmic.child"), "cosmic.child should exist")
  assert(require_mod.module_exists("cosmic.walk"), "cosmic.walk should exist")
  assert(require_mod.module_exists("cosmic.fetch"), "cosmic.fetch should exist")
end
test_module_exists_cosmic()

local function test_module_not_exists()
  assert(not require_mod.module_exists("nonexistent_module_xyz"), "nonexistent module should not exist")
  assert(not require_mod.module_exists("argon2"), "argon2 without prefix should not exist")
end
test_module_not_exists()

local function test_format_error_suggests_cosmo_prefix()
  local err = require_mod.format_error("argon2")
  assert(err:match("cosmo%.argon2"), "should suggest cosmo.argon2, got: " .. err)
  assert(err:match("Did you mean"), "should include 'Did you mean'")
end
test_format_error_suggests_cosmo_prefix()

local function test_format_error_suggests_cosmic_prefix()
  local err = require_mod.format_error("child")
  assert(err:match("cosmic%.child"), "should suggest cosmic.child, got: " .. err)
end
test_format_error_suggests_cosmic_prefix()

local function test_format_error_unknown_module()
  local err = require_mod.format_error("totally_unknown_xyz")
  assert(err:match("cosmic %-%-docs"), "should mention cosmic --docs, got: " .. err)
  assert(err:match("cosmo%.%*.*cosmic%.%*") or err:match("namespace"), "should mention namespaces")
end
test_format_error_unknown_module()

local function test_require_nonexistent_shows_suggestion()
  -- Test that requiring a nonexistent module shows helpful error
  -- Use a variable to prevent Teal from trying to resolve at compile time
  local modname = "argon2"
  local ok, result = pcall(require, modname)
  assert(not ok, "require('argon2') should fail")
  local err_str = tostring(result)
  assert(err_str:match("cosmo%.argon2"), "error should suggest cosmo.argon2, got: " .. err_str)
end
test_require_nonexistent_shows_suggestion()

local function test_require_valid_module_works()
  -- Make sure valid requires still work
  local unix = require("cosmo.unix")
  assert(unix ~= nil, "require('cosmo.unix') should work")

  local spawn = require("cosmic.child")
  assert(spawn ~= nil, "require('cosmic.child') should work")
end
test_require_valid_module_works()

print("All require tests passed")
