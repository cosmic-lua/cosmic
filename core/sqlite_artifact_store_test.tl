--- Inspection must not add loader databases or grant a borrowed store handle
--- an attachment capability; counting the store requires this declaration.
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local fixture = require("build.sql_artifact_fixture")

Test.needs{ store = true }

local function test_inspection_keeps_loader_databases_and_borrowed_handles_unchanged(tmp: string)
  local before = Store.databases()
  local a = assert(Sqlite.artifact(fixture.write(tmp, "a", "not a loaded module")))
  local db = assert(a:open())
  assert(db:attach_artifact(a, "second"))
  assert(#Store.databases() == #before)
  for _, borrowed in ipairs(before) do
    assert(not pcall(function() borrowed:attach_artifact(a, "second") end))
  end
  assert(db:close())
  assert(a:close())
  assert(#Store.databases() == #before)
end
