--- An attached database, walked the way core/allocation_test.tl walks
--- the paths a C binding takes when an allocation fails: the one of its
--- walks that counts the store's databases, apart so the rest stand
--- while the tree moves. Only the checked core can refuse an allocation
--- (core/testing.h), and CI runs this suite on it; on any other the
--- walk returns at once.

local AllocationFixture = require("build.allocation_fixture")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")

--- [`test_attach_leaves_no_connection_whenever_an_allocation_fails`] counts
--- the store's databases, which a test sees only when it declares the store.
Test.policy{ requires = { "checked" }, grants = { { path = "o/cosmic.db", letters = "r" } } }

--- An attached database is held by the store or closed: a refusal
--- leaves no connection -- and no descriptor under it -- behind.
local function test_attach_leaves_no_connection_whenever_an_allocation_fails(tmp: string)
  local path = tmp .. "/project.db"
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE modules (path TEXT, bytecode BLOB, kind TEXT, " ..
      "source TEXT, file TEXT); CREATE TABLE meta (key TEXT, value TEXT)"))
  assert(db:close())
  local before = AllocationFixture.next_descriptor(tmp)
  local searched = #Store.databases()
  local ended = AllocationFixture.under_every_failure(function()
    Store.attach(path, { unchecked_bytecode = true })
  end)
  assert(ended > 0, "attaching allocates")
  -- A run can attach and still count a refusal Lua shrugged off (a
  -- string table it could not grow), so the store may hold more than
  -- one: each holds its one descriptor, and nothing else does.
  local held = #Store.databases() - searched
  assert(held >= 1, "the last run attached")
  local after = AllocationFixture.next_descriptor(tmp)
  assert(after == before + held, "descriptors from " .. tostring(before) .. " to " .. tostring(after) ..
      " for " .. tostring(held) .. " attached: a refused attach left a connection open")
end
