--- What cosmic/net_connector_test.tl and cosmic/internal/connector_test.tl share: a loopback echo server for a
--- connector to dial. Test support.

local Net = require("cosmic.net")
local Poll = require("cosmic.poll")

local record connector_fixture
  --- A running echo server.
  record Echo
    listener: Net.Listener
    --- The task that accepts, to cancel when the test is done.
    task: Poll.Task
  end
end

--- A loopback echo server in the run's tasks: its address, and the task to cancel.
--- @return the listener and its accepting task
function connector_fixture.echo_server(): connector_fixture.Echo
  local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local task = Poll.spawn(function()
    while true do
      local conn, _ = listener:accept()
      if conn == nil then return end
      Poll.spawn(function()
        while true do
          local data, _ = conn:read()
          if data == nil then break end
          local _, _ = conn:write(data)
        end
        local _, _ = conn:close()
      end)
    end
  end)
  return { listener = listener, task = task }
end

return connector_fixture
