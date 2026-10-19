local find = require("lookup")

local function test_find_gives_the_entry_its_name()
  local entry = find("a")
  assert(entry ~= nil and entry.name == "a")
end
