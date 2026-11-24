--- What the tests of cosmic.child that start this program again share
--- (cosmic/child_tool_test.tl and cosmic/child_sandbox_tool_test.tl): the
--- chunks a child runs.

local record child_tool_fixture
end

--- A chunk's statement that sleeps `ms` milliseconds.
--- @param ms how long
--- @return the statement
function child_tool_fixture.sleeping(ms: integer): string
  return 'local _, _ = require("cosmic.clock").sleep(require("cosmic.clock").ms(' .. tostring(ms) .. ')) '
end

return child_tool_fixture
