--- What the tests of cosmic.child that start this program again share
--- (cosmic/child_tool_test.tl and cosmic/child_sandbox_tool_test.tl): the
--- chunks a child runs.

local record child_tool_fixture
  --- A prefix for a chunk that starts a descendant: `again(chunk, opts)`
  --- starts this program once more, as `lua` does, running `chunk`.
  --- A chunk that leaves one running ends by [`sys.exit`], past the
  --- collector, whose end of the handle would end it, as a shell's `&`
  --- leaves it.
  AGAIN: string
end

child_tool_fixture.AGAIN = [[
local Child = require("cosmic.child")
local this_program = require("build.this_program")
local function again(chunk, opts)
  local started = this_program.program({ "-e", chunk }, opts)
  return assert(Child.start(started.argv, started.options))
end
]]

--- A chunk's statement that sleeps `ms` milliseconds.
--- @param ms how long
--- @return the statement
function child_tool_fixture.sleeping(ms: integer): string
  return 'require("cosmic.clock").sleep_ns(require("cosmic.clock").ms(' .. tostring(ms) .. ')) '
end

return child_tool_fixture
