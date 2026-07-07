#!/usr/bin/env cosmic
local uuid = require("cosmic.uuid")

-- UUID format pattern: 8-4-4-4-12 hex digits
local uuid_pattern = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

-- v4 tests

local function test_v4_returns_string()
  local id = uuid.v4()
  assert(type(id) == "string", "v4 should return a string, got " .. type(id))
end
test_v4_returns_string()

local function test_v4_format()
  local id = uuid.v4()
  assert(id:match(uuid_pattern), "v4 should return valid UUID format, got " .. id)
end
test_v4_format()

local function test_v4_version_digit()
  local id = uuid.v4()
  local version = id:sub(15, 15)
  assert(version == "4", "v4 should have version digit 4, got " .. version .. " in " .. id)
end
test_v4_version_digit()

local function test_v4_unique()
  local id1 = uuid.v4()
  local id2 = uuid.v4()
  assert(id1 ~= id2, "v4 should generate unique UUIDs")
end
test_v4_unique()

-- v7 tests

local function test_v7_returns_string()
  local id = uuid.v7()
  assert(type(id) == "string", "v7 should return a string, got " .. type(id))
end
test_v7_returns_string()

local function test_v7_format()
  local id = uuid.v7()
  assert(id:match(uuid_pattern), "v7 should return valid UUID format, got " .. id)
end
test_v7_format()

local function test_v7_version_digit()
  local id = uuid.v7()
  local version = id:sub(15, 15)
  assert(version == "7", "v7 should have version digit 7, got " .. version .. " in " .. id)
end
test_v7_version_digit()

local function test_v7_unique()
  local id1 = uuid.v7()
  local id2 = uuid.v7()
  assert(id1 ~= id2, "v7 should generate unique UUIDs")
end
test_v7_unique()

-- v7 leads with time: a 48-bit unix-ms timestamp plus a 12-bit
-- sub-millisecond fraction fill chars 1-18, so UUIDs from different
-- ~244ns ticks order lexicographically. Everything after char 18 is
-- random, and RFC 9562's same-tick monotonicity (a counter) is
-- optional and not implemented — two UUIDs minted inside one tick may
-- sort either way. Assert exactly the guarantee: the time-bearing
-- prefix never decreases, and same-tick UUIDs are still unique.
local function test_v7_time_ordered()
  local ids: {string} = {}
  for _ = 1, 10 do
    table.insert(ids, uuid.v7())
  end
  for i = 2, #ids do
    local prev, cur = ids[i - 1], ids[i]
    assert(prev:sub(1, 18) <= cur:sub(1, 18),
      "v7 time-bearing prefix must not decrease, but " .. prev .. " then " .. cur)
    assert(prev ~= cur, "v7 UUIDs in the same tick must still be unique: " .. cur)
  end
end
test_v7_time_ordered()
