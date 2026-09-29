--- `cosmic.test`'s `Needs`, in this process: each field is one `fields`
--- names. cosmic/test_tool_test.tl holds `needs` as it runs, which a
--- script run by this program shows.

local Test = require("cosmic.test")

--- Each field `Needs` has is one `fields` names, taking what the type
--- does, so the checks the build and `needs` make keep to the type.
local function test_every_field_of_needs_is_one_fields_names()
  local every: Test.Needs = {
    reads = {}, host = {}, env = {}, network = true, processes = true, tool = true,
    nests = true, store = true, system = true, caches = {},
  }
  local want: {string:string} = {
    reads = "list", host = "list", env = "list", network = "either",
    processes = "flag", tool = "flag", nests = "flag", store = "flag", system = "flag",
    caches = "list",
  }
  local count = 0
  for name in pairs(every as {string:any}) do
    count = count + 1
    assert(Test.fields[name] == want[name], name)
  end
  for _ in pairs(Test.fields) do count = count - 1 end
  assert(count == 0, "fields names one Needs does not have")
end
