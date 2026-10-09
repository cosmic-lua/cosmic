local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")
local Udp = require("build.udp_fixture")

Test.policy{ loopback = { "127.0.0.1" } }

local function bind(): Udp.Bound
  return (assert(Udp.bind("127.0.0.1", 0)))
end

local function test_packets_keep_their_boundaries_and_name_their_sender()
  local server <close> = bind()
  local client <close> = bind()
  assert(server.address.kind == "udp" and server.address.port > 0)
  for _, data in ipairs({ "a\0b", "", "third" }) do
    assert(Udp.send(client, data, server.address))
  end
  for _, data in ipairs({ "a\0b", "", "third" }) do
    local packet = assert(Udp.receive(server, Clock.seconds(5)))
    assert(packet.data == data)
    assert(packet.address.host == "127.0.0.1" and packet.address.port == client.address.port)
  end
end

local function test_a_receive_with_nothing_waiting_times_out()
  local server <close> = bind()
  local packet, why = Udp.receive(server, 0)
  assert(packet == nil and why == Poll.TIMEOUT, why)
end

local function test_close_ends_a_wait_and_is_idempotent()
  local server = bind()
  local answer = ""
  Poll.run(function()
    Poll.spawn(function()
      local packet, why = Udp.receive(server)
      assert(packet == nil)
      answer = why
    end)
    Poll.spawn(function()
      Udp.close(server)
      Udp.close(server)
    end)
  end)
  assert(answer == "closed", answer)
end

local function test_only_numeric_hosts_bind_and_a_port_is_not_shared()
  for _, host in ipairs({ "localhost", "127.1", "2130706433", "0x7f.0.0.1", "127.0.0.1\0evil" }) do
    local bound = Udp.bind(host, 0)
    assert(bound == nil, "bound " .. string.format("%q", host))
  end
  local server <close> = bind()
  local other, why = Udp.bind("127.0.0.1", server.address.port)
  assert(other == nil and why == "Address in use", why)
end
