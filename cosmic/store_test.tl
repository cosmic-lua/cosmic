--- [`cosmic.store`]'s cases that read nothing beyond this module's
--- closure: an attach that fails. The tz database the binary carries is
--- cosmic/time_zone_test.tl's, whose closure holds the module that reads it.
--- cosmic/store_handles_test.tl holds those that read the
--- store's handles, and cosmic/store_tool_test.tl the one that starts
--- this program.

local Store = require("cosmic.store")

local function test_attaching_a_missing_database_fails(tmp: string)
  local path = tmp .. "/missing.db"
  local ok, trouble = Store.attach(path)
  assert(not ok, "attached a database that does not exist")
  assert(trouble:sub(1, #path + 2) == path .. ": ", trouble)
end
