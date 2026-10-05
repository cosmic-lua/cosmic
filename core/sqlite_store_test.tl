--- Borrowed store connections outlive their Lua wrappers.
local Store = require("cosmic.store")
local Test = require("cosmic.test")

-- The test asks for borrowed handles over the store's own databases.
Test.policy{ grants = { { path = "o/cosmic.db", letters = "r" } } }

local function test_a_borrowed_handle_cannot_install_a_busy_callback()
  local databases = Store.databases()
  assert(#databases > 0)
  for _, db in ipairs(databases) do
    local ok, reason = pcall(function(): any
      db:busy_timeout(0)
      return nil
    end)
    assert(not ok and tostring(reason):find("borrowed handle", 1, true))
    assert(db:exec("SELECT 1"))
    assert(db:close())
  end
  collectgarbage("collect")
  for _, db in ipairs(Store.databases()) do
    assert(db:exec("SELECT 1"))
    assert(db:close())
  end
end
