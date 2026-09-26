--- Worked examples for `cosmic.test`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Env = require("cosmic.env")
local Test = require("cosmic.test")

-- These examples read USER, which a test reads only once it says so.
Test.needs{ env = { "USER" } }

local Example = {}

--- A test module declares what its tests read beyond their own sources
--- once, as a statement at its top: the call above, which lets the
--- examples below read USER.
function Example.needs()
  local user = Env.get("USER")
  print(user ~= nil)
end

return Example
