--- Worked examples for [`cosmic.test`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Env = require("cosmic.env")
local Test = require("cosmic.test")

-- These examples read USER, which a test reads only once it says so.
Test.policy{ env = { "USER" } }

local Example = {}

--- A test module declares what its tests read beyond their own sources
--- once, as a statement at its top: the call above, which lets the
--- examples below read USER.
function Example.needs()
  local user = Env.get("USER")
  print(user ~= nil)
end

--- A file of the directory above the project root is read at the path
--- `parent` returns, for a file the policy grants as
--- `{ path = "/parent/<file>", letters = "r" }`. It raises for one the
--- module never declared.
function Example.parent()
  local ok, _ = pcall(Test.parent, "bin/zig")
  print(ok) -- false
end

return Example
