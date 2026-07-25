#!/usr/bin/env cosmic

local stage = require("_build.build-stage")

-- validate_stage_path tests

local function test_validate_stage_path_ok_simple()
  local err = stage.validate_stage_path("foo")
  assert(err == nil, "expected nil for simple path, got: " .. tostring(err))
end
test_validate_stage_path_ok_simple()

local function test_validate_stage_path_ok_nested()
  local err = stage.validate_stage_path("foo/bar/baz")
  assert(err == nil, "expected nil for nested path, got: " .. tostring(err))
end
test_validate_stage_path_ok_nested()

local function test_validate_stage_path_empty()
  local err = stage.validate_stage_path("")
  assert(err ~= nil, "expected error for empty path")
  assert(err:match("empty"), "expected 'empty' in error, got: " .. tostring(err))
end
test_validate_stage_path_empty()

local function test_validate_stage_path_absolute()
  local err = stage.validate_stage_path("/etc/passwd")
  assert(err ~= nil, "expected error for absolute path")
  assert(err:match("absolute"), "expected 'absolute' in error, got: " .. tostring(err))
end
test_validate_stage_path_absolute()

local function test_validate_stage_path_dotdot()
  local err = stage.validate_stage_path("../etc/passwd")
  assert(err ~= nil, "expected error for .. path")
  assert(err:match("%.%."), "expected '..' in error, got: " .. tostring(err))
end
test_validate_stage_path_dotdot()

local function test_validate_stage_path_dotdot_middle()
  local err = stage.validate_stage_path("foo/../etc/passwd")
  assert(err ~= nil, "expected error for .. in middle of path")
  assert(err:match("%.%."), "expected '..' in error, got: " .. tostring(err))
end
test_validate_stage_path_dotdot_middle()

local function test_validate_stage_path_dotdot_dst()
  -- this specifically tests the .. in dst scenario from the spec
  local err = stage.validate_stage_path("../outside")
  assert(err ~= nil, "expected error for ../outside dst")
end
test_validate_stage_path_dotdot_dst()

-- validate_link_target tests

local function test_validate_link_target_ok()
  local err = stage.validate_link_target("lib/libfoo.so")
  assert(err == nil, "expected nil for valid relative target, got: " .. tostring(err))
end
test_validate_link_target_ok()

local function test_validate_link_target_empty()
  local err = stage.validate_link_target("")
  assert(err ~= nil, "expected error for empty target")
  assert(err:match("empty"), "expected 'empty' in error, got: " .. tostring(err))
end
test_validate_link_target_empty()

local function test_validate_link_target_absolute()
  local err = stage.validate_link_target("/usr/lib/libfoo.so")
  assert(err ~= nil, "expected error for absolute target")
  assert(err:match("absolute"), "expected 'absolute' in error, got: " .. tostring(err))
end
test_validate_link_target_absolute()

local function test_validate_link_target_dotdot()
  local err = stage.validate_link_target("../x")
  assert(err ~= nil, "expected error for ../x target")
  assert(err:match("%.%."), "expected '..' in error, got: " .. tostring(err))
end
test_validate_link_target_dotdot()

local function test_validate_link_target_dotdot_nested()
  local err = stage.validate_link_target("foo/../../escape")
  assert(err ~= nil, "expected error for escaping target via ..")
end
test_validate_link_target_dotdot_nested()
