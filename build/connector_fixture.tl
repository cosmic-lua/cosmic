--- What cosmic/net_connector_test.tl and cosmic/internal/connector_test.tl share: a loopback echo server for a
--- connector to dial. Test support.

local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local process = require("cosmic.internal.process")

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

--- Ends the test where this host has no native connector confinement; fails it where the confined setup is wrong.
function connector_fixture.require_native_connector()
  local result, why, number = process.connector_probe({ host = "127.0.0.1", port = 9 }, "pointer")
  if result == nil and (number == sys.ENOSYS or number == sys.EOPNOTSUPP) then
    Test.skip("this host has no native connector confinement: " .. why)
  end
  assert(result == sys.EPERM, "native connector setup failed: " .. tostring(why))
end

--- Reads exactly `count` bytes.
--- @param conn the connection to read
--- @param count how many bytes
--- @return what was read
function connector_fixture.read_exact(conn: Net.Conn, count: integer): string
  local out = ""
  while #out < count do
    local data, why = conn:read(count - #out)
    assert(data ~= nil, "the connection ended with " .. tostring(#out) .. " read of " .. tostring(count) .. " wanted: " .. why)
    out = out .. data
  end
  return out
end

return connector_fixture
