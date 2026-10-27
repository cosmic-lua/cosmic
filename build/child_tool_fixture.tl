--- What the tests of cosmic.child that start this program again share
--- (cosmic/child_tool_test.tl and cosmic/child_sandbox_tool_test.tl): the
--- chunks a child runs.

local child_lua_fixture = require("build.child_lua_fixture")

local record child_tool_fixture
  --- A prefix for a chunk that starts a descendant: `again(chunk, opts)`
  --- starts this program once more, as `lua` does, running `chunk`.
  --- A chunk that leaves one running ends by [`sys.exit`], past the
  --- collector, whose end of the handle would end it, as a shell's `&`
  --- leaves it.
  AGAIN: string
end

child_tool_fixture.AGAIN = child_lua_fixture.AGAIN

--- A chunk's statement that sleeps `ms` milliseconds.
--- @param ms how long
--- @return the statement
function child_tool_fixture.sleeping(ms: integer): string
  return 'require("cosmic.clock").sleep_ns(require("cosmic.clock").ms(' .. tostring(ms) .. ')) '
end

return child_tool_fixture
