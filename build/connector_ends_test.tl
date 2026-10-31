--- The ends of a connector pair and the port of a listener, as [`build.connector_ends`] reads them.
local ConnectorEnds = require("build.connector_ends")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")

Test.policy{ loopback = { "127.0.0.1" } }

--- The message `body` raises, or "" when it raises none.
local function refused(body: function()): string
  local ok, err = pcall(body)
  if ok then return "" end
  return tostring(err)
end

local function test_a_connector_pair_is_held_as_its_two_ends()
  local made = ConnectorEnds.connector_pair()
  assert(made.controller ~= made.connector)
  assert(sys.close(made.controller))
  assert(sys.close(made.connector))
  local held = ConnectorEnds.pair_ends({ 7, 8 })
  assert(held.controller == 7 and held.connector == 8)
  assert(refused(function() local _ = ConnectorEnds.pair_ends({ 7 }) end):find("holds two descriptors", 1, true) ~= nil)
  assert(refused(function() local _ = ConnectorEnds.pair_ends({}) end):find("holds two descriptors", 1, true) ~= nil)
end

local function test_the_port_of_a_listener_is_the_one_the_kernel_gave()
  local socket = require("cosmic.internal.socket")
  local listener <close> = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 1))
  local port = ConnectorEnds.bound_port(listener)
  assert(port > 0 and port < 65536)
  local address = assert(socket.bound(listener:fd()))
  assert(address.port == port)
end
