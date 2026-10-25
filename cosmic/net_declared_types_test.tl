--- The declarations of cosmic.net tell the truth about nil: a connection
--- or a listener with no timeout has no limit to hold, and a socket handed
--- on is no longer the connecting task's. A checked run
--- (`cosmic test --check-types`) says whether a value crossed a typed
--- boundary as a kind its type does not admit; in any other run the
--- tests skip.
--- Until a compile writes the boundary checks (build/type_watch.tl), they skip in a checked run too.

local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")
local TypeWatch = require("build.type_watch")

Test.policy{ loopback = { "127.0.0.1" } }

local function test_a_connection_with_no_timeout_is_as_declared()
  local found = TypeWatch.during(function()
    local server = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local client = assert(Net.connect(server.address))
    local accepted = assert(server:accept())
    client:set_timeout(nil)
    accepted:set_timeout(nil)
    server:set_timeout(nil)
    assert(client:write("x"))
    assert(accepted:read(1) == "x")
    assert(accepted:close() and client:close() and server:close())
    -- Connected in a task, where the socket is handed on to the caller.
    local ahead = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    Poll.run(function()
      local conn = assert(Net.connect(ahead.address))
      assert(conn:close())
    end)
    assert(ahead:close())
  end)
  assert(#found == 0, #found .. " violations:\n" .. table.concat(found, "\n"))
end
