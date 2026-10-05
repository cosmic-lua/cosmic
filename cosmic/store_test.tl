--- [`cosmic.store`]'s cases that read nothing beyond this module's
--- closure: an attach that fails, and the tz database the binary
--- carries. cosmic/store_handles_test.tl holds those that read the
--- store's handles, and cosmic/store_tool_test.tl the one that starts
--- this program.

local Store = require("cosmic.store")
local Test = require("cosmic.test")

-- Declared for the tz database the program's own database carries, which
-- a sealed database holds only for a program that requires cosmic.time.
Test.needs{ store = true }

local function test_attaching_a_missing_database_fails(tmp: string)
  local path = tmp .. "/missing.db"
  local ok, trouble = Store.attach(path)
  assert(not ok, "attached a database that does not exist")
  assert(trouble:sub(1, #path + 2) == path .. ": ", trouble)
end

--- The binary carries the tz database, one TZif file per zone.
local function test_the_binary_carries_the_zones()
  local data, why = Store.zoneinfo("America/New_York")
  assert(data ~= nil, why)
  assert(data:sub(1, 4) == "TZif", "a TZif file")
  local none, trouble = Store.zoneinfo("Nowhere/Nothing")
  assert(none == nil and trouble:find("Nowhere/Nothing", 1, true), trouble)
end
