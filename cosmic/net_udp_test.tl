local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" } }

local function socket(): Net.Datagram
  return (assert(Net.datagram(Net.udp("127.0.0.1", 0), { timeout_ns = Clock.seconds(5) })))
end

local function test_datagrams_preserve_sender_empty_packets_and_boundaries()
  local server <close> = socket()
  local client <close> = socket()
  assert(server.address.kind == "udp" and server.address.port > 0)
  for _, data in ipairs({ "a\0b", "", "third" }) do
    assert(client:send(data, server.address))
  end
  for _, data in ipairs({ "a\0b", "", "third" }) do
    local packet = assert(server:receive())
    assert(packet.data == data)
    assert(packet.address.kind == "udp" and packet.address.host == "127.0.0.1")
    assert(packet.address.port == client.address.port)
    assert(server:send(packet.data, packet.address))
    assert(assert(client:receive()).data == data)
  end
end

local function test_truncated_datagrams_are_refused_and_the_next_is_readable()
  local server <close> = socket()
  local client <close> = socket()
  assert(client:send("too long", server.address))
  assert(client:send("ok", server.address))
  local packet, why = server:receive(2)
  assert(packet == nil and why == "Message too large", why)
  assert(assert(server:receive(2)).data == "ok")
end

local function test_a_timeout_does_not_consume_the_next_packet()
  local server <close> = socket()
  local client <close> = socket()
  server:set_timeout(0)
  local packet, why = server:receive()
  assert(packet == nil and why == Poll.TIMEOUT, why)
  assert(client:send("after", server.address))
  server:set_timeout(Clock.seconds(5))
  assert(assert(server:receive()).data == "after")
end

local function test_datagrams_wait_through_a_poll_run()
  local server <close> = socket()
  local client <close> = socket()
  local got = ""
  Poll.run(function()
    Poll.spawn(function()
      local packet = assert(server:receive())
      got = packet.data
    end)
    Poll.spawn(function()
      assert(client:send("concurrent", server.address))
    end)
  end)
  assert(got == "concurrent")
end

local function test_close_ends_a_wait_and_is_idempotent()
  local server = socket()
  local answer = ""
  Poll.run(function()
    Poll.spawn(function()
      local packet, why = server:receive()
      assert(packet == nil)
      answer = why
    end)
    Poll.spawn(function()
      assert(server:close())
      assert(server:close())
    end)
  end)
  assert(answer == "net: the datagram socket is closed", answer)
  assert(not server:send("closed", Net.udp("127.0.0.1", 1)))
end

local function test_numeric_hosts_only_and_no_shared_ports()
  for _, host in ipairs({ "localhost", "127.1", "2130706433", "0177.0.0.1", "127.00.0.1",
      "0x7f.0.0.1", "127.0.0.1\0evil", "::1%lo", "::ffff:127.1", "::ffff:127.00.0.1" }) do
    local bound, why = Net.datagram(Net.udp(host, 0))
    assert(bound == nil and why:find("not a numeric", 1, true) ~= nil,
      "host " .. string.format("%q", host) .. ": " .. why)
  end
  local server <close> = socket()
  local other, why = Net.datagram(server.address)
  assert(other == nil and why == "Address in use", why)
end

local function test_bad_arguments_raise()
  local server <close> = socket()
  for _, size in ipairs({ 0, 65536, math.maxinteger }) do
    assert(not pcall(server.receive, server, size))
  end
  assert(not pcall(server.send, server, string.rep("x", 65536), server.address))
  assert(not pcall(Net.datagram, Net.tcp("127.0.0.1", 0)))
  assert(not pcall(Net.listen, Net.udp("127.0.0.1", 0)))
  assert(not pcall(Net.connect, Net.udp("127.0.0.1", 1)))
  assert(not pcall(server.send, server, "x", Net.tcp("127.0.0.1", 1)))
end
