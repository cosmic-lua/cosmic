#!/usr/bin/env cosmic

-- Note: TEST_DEPS tests removed - TEST_DEPS is a Make variable not passed to Lua tests

local function test_env_vars()
  assert(os.getenv("TEST_O") ~= nil, "TEST_O should be set")
  assert(os.getenv("TEST_PLATFORM") ~= nil, "TEST_PLATFORM should be set")
end
test_env_vars()

local function test_require_cosmic()
  local cosmic = require("cosmic")
  assert(cosmic ~= nil, "cosmic should not be nil")
  assert(type(cosmic._VERSION) == "string" and cosmic._VERSION ~= "",
    "expected build-injected version string, got " .. tostring(cosmic._VERSION))
  assert(cosmic._VERSION ~= "0.1.0", "version must not be the old hardcoded 0.1.0")
end
test_require_cosmic()

local function test_require_cosmic_spawn()
  local spawn_mod = require("cosmic.child")
  assert(spawn_mod ~= nil, "spawn_mod should not be nil")
  assert(spawn_mod.spawn ~= nil, "spawn_mod.spawn should not be nil")
end
test_require_cosmic_spawn()

local function test_require_cosmic_fs()
  local fs = require("cosmic.fs")
  assert(fs ~= nil, "fs should not be nil")
  -- Path functions
  assert(fs.dirname ~= nil, "fs.dirname should not be nil")
  assert(fs.basename ~= nil, "fs.basename should not be nil")
  assert(fs.join ~= nil, "fs.join should not be nil")
  -- Walk functions
  assert(fs.walk ~= nil, "fs.walk should not be nil")
  assert(fs.collect ~= nil, "fs.collect should not be nil")
  assert(fs.collect_all ~= nil, "fs.collect_all should not be nil")
  assert(fs.files ~= nil, "fs.files should not be nil")
end
test_require_cosmic_fs()

local function test_cosmic_main_exists()
  local cosmic = require("cosmic")
  assert(cosmic.main ~= nil, "cosmic.main should not be nil")
  assert(type(cosmic.main) == "function", "expected cosmic.main to be function, got " .. type(cosmic.main))
end
test_cosmic_main_exists()

local function test_cosmic_main_returns_when_not_main()
  local cosmic = require("cosmic")
  local called = false
  local function app(): number
    called = true
    return 0
  end
  -- when required (not main), cosmic.main should return without calling fn
  cosmic.main(app as function({string}, any): number, string)
  assert(not called, "expected app not to be called when not main")
end
test_cosmic_main_returns_when_not_main()
