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
  assert(env.set("COSMIC_TEST_OVERWRITE", "original"))
  local ok = env.set("COSMIC_TEST_OVERWRITE", "updated", true)
  assert(ok, "set with overwrite=true should succeed")
  local value = env.get("COSMIC_TEST_OVERWRITE")
  assert(value == "updated", "expected 'updated', got '" .. tostring(value) .. "'")
end
test_set_overwrite_true()

local function test_set_overwrite_false()
  assert(env.set("COSMIC_TEST_NO_OVERWRITE", "original"))
  local ok = env.set("COSMIC_TEST_NO_OVERWRITE", "should_not_change", false)
  assert(ok, "set with overwrite=false should succeed even when not overwriting")
  local value = env.get("COSMIC_TEST_NO_OVERWRITE")
  assert(value == "original", "expected 'original', got '" .. tostring(value) .. "'")
end
test_set_overwrite_false()

local function test_unset()
  assert(env.set("COSMIC_TEST_TO_UNSET", "will_be_removed"))
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
  assert(env.set("COSMIC_TEST_ALL_CHECK", "check_value"))
  local vars = env.all()
  assert(type(vars) == "table", "all() should return a table")
  -- all() should parse KEY=VALUE entries into a proper map
  assert(vars["COSMIC_TEST_ALL_CHECK"] == "check_value",
    "expected 'check_value', got '" .. tostring(vars["COSMIC_TEST_ALL_CHECK"]) .. "'")
  assert(env.unset("COSMIC_TEST_ALL_CHECK"))
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
  assert(env.set("COSMIC_TEST_LIST_CHECK", "list_value"))
  local entries = env.list()
  local found = false
  for _, entry in ipairs(entries) do
    if entry == "COSMIC_TEST_LIST_CHECK=list_value" then
      found = true
      break
    end
  end
  assert(found, "list() should include COSMIC_TEST_LIST_CHECK=list_value")
  assert(env.unset("COSMIC_TEST_LIST_CHECK"))
end
test_list_includes_set_variable()

local function test_list_edits()
  assert(env.set("COSMIC_TEST_DROP_ME", "x"))
  assert(env.set("COSMIC_TEST_KEEP_ME", "old"))
  local entries = env.list({
      drop = {"COSMIC_TEST_DROP_ME"},
      set = {COSMIC_TEST_KEEP_ME = "new", COSMIC_TEST_ADDED = "fresh"},
    })
  local seen: {string: string} = {}
  for _, entry in ipairs(entries) do
    local eq = entry:find("=", 1, true)
    if eq then
      seen[entry:sub(1, eq - 1)] = entry:sub(eq + 1)
    end
  end
  assert(seen["COSMIC_TEST_DROP_ME"] == nil, "drop removes the variable")
  assert(seen["COSMIC_TEST_KEEP_ME"] == "new", "set overrides in place")
  assert(seen["COSMIC_TEST_ADDED"] == "fresh", "set appends missing names")
  -- the edits touch only the returned copy
  assert(env.get("COSMIC_TEST_DROP_ME") == "x", "parent env is untouched")
  assert(env.get("COSMIC_TEST_KEEP_ME") == "old", "parent env is untouched")
  assert(env.unset("COSMIC_TEST_DROP_ME"))
  assert(env.unset("COSMIC_TEST_KEEP_ME"))
end
test_list_edits()

local function test_set_empty_value()
  local ok = env.set("COSMIC_TEST_EMPTY", "")
  assert(ok, "set with empty value should succeed")
  local value = env.get("COSMIC_TEST_EMPTY")
  assert(value == "", "expected empty string, got '" .. tostring(value) .. "'")
  assert(env.unset("COSMIC_TEST_EMPTY"))
end
test_set_empty_value()

-- Clean up test variables
assert(env.unset("COSMIC_TEST_VAR"))
assert(env.unset("COSMIC_TEST_OVERWRITE"))
assert(env.unset("COSMIC_TEST_NO_OVERWRITE"))

local function test_get_default_when_unset()
  assert(env.unset("COSMIC_TEST_DEFAULT"))
  local value = env.get_or("COSMIC_TEST_DEFAULT", "fallback")
  assert(value == "fallback", "expected default, got '" .. tostring(value) .. "'")
  assert(env.get("COSMIC_TEST_DEFAULT") == nil,
    "without a default, unset should still be nil")
end
test_get_default_when_unset()

local function test_get_default_ignored_when_set()
  assert(env.set("COSMIC_TEST_DEFAULT", "real"))
  local value = env.get_or("COSMIC_TEST_DEFAULT", "fallback")
  assert(value == "real", "set value should win over default, got '" .. tostring(value) .. "'")
  assert(env.unset("COSMIC_TEST_DEFAULT"))
end
test_get_default_ignored_when_set()

local function test_get_default_empty_value_wins()
  assert(env.set("COSMIC_TEST_DEFAULT", ""))
  local value = env.get_or("COSMIC_TEST_DEFAULT", "fallback")
  assert(value == "", "empty string is set, default must not apply")
  assert(env.unset("COSMIC_TEST_DEFAULT"))
end
test_get_default_empty_value_wins()

-- The bug this shape closes, asserted where it lives: in the TYPE.
--
-- A `get` with an optional default and a bare `string` return hides
-- the failure. With no default the body returns the parameter --
-- `string` inside the function, nil at the call site -- so the checker
-- never sees the nil escape, and an unguarded use of the result
-- type-checks strictly, then crashes. That is a silent bug of exactly
-- the class the honest-nil rule exists to stop.
--
-- What the honest type buys, precisely: Teal 0.24.8 checks nilability at
-- the USE, not at the assignment. `local v: string = get(x)` is still
-- accepted (the declaration is taken at its word); `get(x):match(...)`
-- is not. The use site is where the crash was, and it is the one this
-- pins -- `_make/stage_test.tl` had exactly that line, and the honest
-- return type is what surfaced it.
--
-- A runtime assertion cannot pin a type, so this asks the checker.
local function test_get_admits_nil_in_its_type()
  local fs = require("cosmic.fs")
  local teal = require("cosmic.teal")
  local dir = env.get_or("TEST_TMPDIR", "/tmp")
  local bad = fs.join(dir, "env_nil_use.tl")
  assert(fs.write(bad, 'local e = require("cosmic.env")\n'
      .. 'print(e.get("DEFINITELY_NOT_SET"):upper())\n'))
  -- `.` first, so `cosmic.env` resolves to THIS tree's copy rather than
  -- to whatever the running binary embeds.
  local result = teal.check(bad, {include_dirs = {"."}})
  assert(not result.ok, "using env.get()'s result unguarded must not check")
  local named = false
  for _, e in ipairs(result.errors) do
    if e.message:find("string | nil", 1, true) then
      named = true
    end
  end
  assert(named, "and the error must name the nil the type admits")

  -- The narrowed form is accepted, so the type is honest rather than
  -- merely obstructive.
  local good = fs.join(dir, "env_nil_ok.tl")
  assert(fs.write(good, 'local e = require("cosmic.env")\n'
      .. 'print(e.get_or("DEFINITELY_NOT_SET", "d"):upper())\n'))
  assert(teal.check(good, {include_dirs = {"."}}).ok,
    "get_or cannot fail, so its result needs no narrowing")
end
test_get_admits_nil_in_its_type()
