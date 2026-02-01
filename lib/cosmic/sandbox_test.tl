#!/usr/bin/env cosmic
local sandbox = require("cosmic.sandbox")

-- Test that sandbox module exports expected functions

local function test_module_exports()
  assert(sandbox.pledge ~= nil, "pledge function should be exported")
  assert(sandbox.unveil ~= nil, "unveil function should be exported")
  assert(type(sandbox.pledge) == "function", "pledge should be a function")
  assert(type(sandbox.unveil) == "function", "unveil should be a function")
end
test_module_exports()

-- Note: We cannot fully test pledge and unveil in the test suite because:
-- 1. pledge is irreversible and would affect other tests
-- 2. unveil requires careful setup and is also irreversible once committed
-- These functions are tested by verifying they exist and are callable.
-- Real integration tests would need to run in isolated subprocesses.

local function test_pledge_exists()
  -- Just verify the function can be referenced without error
  local fn = sandbox.pledge
  assert(fn ~= nil, "pledge should be accessible")
end
test_pledge_exists()

local function test_unveil_exists()
  -- Just verify the function can be referenced without error
  local fn = sandbox.unveil
  assert(fn ~= nil, "unveil should be accessible")
end
test_unveil_exists()
