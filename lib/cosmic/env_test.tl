#!/usr/bin/env cosmic
local env = require("cosmic.env")

local function test_get_existing_variable()
  -- TEST_BIN is set by the test harness
  local test_bin = env.get("TEST_BIN")
  assert(test_bin ~= nil, "TEST_BIN should be set")
  assert(type(test_bin) == "string", "TEST_BIN should be a string")
end
test_get_existing_variable()

local function test_get_nonexistent_variable()
  local value = env.get("COSMIC_TEST_NONEXISTENT_VAR_12345")
  assert(value == nil, "nonexistent variable should return nil")
end
test_get_nonexistent_variable()

local function test_set_and_get()
  local ok, err = env.set("COSMIC_TEST_VAR", "test_value")
  assert(ok, "set should succeed: " .. tostring(err))
  local value = env.get("COSMIC_TEST_VAR")
  assert(value == "test_value", "expected 'test_value', got '" .. tostring(value) .. "'")
end
test_set_and_get()

local function test_set_overwrite_true()
  env.set("COSMIC_TEST_OVERWRITE", "original")
  local ok = env.set("COSMIC_TEST_OVERWRITE", "updated", true)
  assert(ok, "set with overwrite=true should succeed")
  local value = env.get("COSMIC_TEST_OVERWRITE")
  assert(value == "updated", "expected 'updated', got '" .. tostring(value) .. "'")
end
test_set_overwrite_true()

local function test_set_overwrite_false()
  env.set("COSMIC_TEST_NO_OVERWRITE", "original")
  local ok = env.set("COSMIC_TEST_NO_OVERWRITE", "should_not_change", false)
  assert(ok, "set with overwrite=false should succeed even when not overwriting")
  local value = env.get("COSMIC_TEST_NO_OVERWRITE")
  assert(value == "original", "expected 'original', got '" .. tostring(value) .. "'")
end
test_set_overwrite_false()

local function test_unset()
  env.set("COSMIC_TEST_TO_UNSET", "will_be_removed")
  local value = env.get("COSMIC_TEST_TO_UNSET")
  assert(value == "will_be_removed", "variable should be set before unset")

  local ok, err = env.unset("COSMIC_TEST_TO_UNSET")
  assert(ok, "unset should succeed: " .. tostring(err))

  value = env.get("COSMIC_TEST_TO_UNSET")
  assert(value == nil, "variable should be nil after unset")
end
test_unset()

local function test_unset_nonexistent()
  -- Unsetting a nonexistent variable should succeed (POSIX behavior)
  local ok = env.unset("COSMIC_TEST_NEVER_EXISTED_12345")
  assert(ok, "unset of nonexistent variable should succeed")
end
test_unset_nonexistent()

local function test_all()
  local vars = env.all()
  assert(type(vars) == "table", "all() should return a table")
  -- Verify we got some entries
  local count = 0
  for _ in pairs(vars) do
    count = count + 1
  end
  assert(count > 0, "all() should return non-empty table")
end
test_all()

local function test_all_includes_set_variable()
  env.set("COSMIC_TEST_ALL_CHECK", "check_value")
  local vars = env.all()
  assert(type(vars) == "table", "all() should return a table")
  -- all() should parse KEY=VALUE entries into a proper map
  assert(vars["COSMIC_TEST_ALL_CHECK"] == "check_value",
    "expected 'check_value', got '" .. tostring(vars["COSMIC_TEST_ALL_CHECK"]) .. "'")
  env.unset("COSMIC_TEST_ALL_CHECK")
end
test_all_includes_set_variable()

local function test_list()
  local entries = env.list()
  assert(type(entries) == "table", "list() should return a table")
  assert(#entries > 0, "list() should return non-empty list")
  -- verify entries are "KEY=VALUE" strings
  for _, entry in ipairs(entries) do
    assert(type(entry) == "string", "list entry should be a string")
    assert(entry:find("=", 1, true), "list entry should contain '=': " .. entry)
  end
end
test_list()

local function test_list_includes_set_variable()
  env.set("COSMIC_TEST_LIST_CHECK", "list_value")
  local entries = env.list()
  local found = false
  for _, entry in ipairs(entries) do
    if entry == "COSMIC_TEST_LIST_CHECK=list_value" then
      found = true
      break
    end
  end
  assert(found, "list() should include COSMIC_TEST_LIST_CHECK=list_value")
  env.unset("COSMIC_TEST_LIST_CHECK")
end
test_list_includes_set_variable()

local function test_set_empty_value()
  local ok = env.set("COSMIC_TEST_EMPTY", "")
  assert(ok, "set with empty value should succeed")
  local value = env.get("COSMIC_TEST_EMPTY")
  assert(value == "", "expected empty string, got '" .. tostring(value) .. "'")
  env.unset("COSMIC_TEST_EMPTY")
end
test_set_empty_value()

-- Note: We don't test clear() directly because it would remove all environment
-- variables including PATH, HOME, etc., which would break subsequent tests and
-- potentially the test harness itself. The clear() function is a thin wrapper
-- around unix.clearenv() and is tested indirectly through the other tests.

-- Clean up test variables
env.unset("COSMIC_TEST_VAR")
env.unset("COSMIC_TEST_OVERWRITE")
env.unset("COSMIC_TEST_NO_OVERWRITE")
