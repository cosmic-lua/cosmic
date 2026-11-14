--- [`Net.datagram`]: a UDP socket keeps each datagram whole and says
--- where it came from, and its waits end as every wait of
--- [`cosmic.net`] does.

local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" } }

local function bound(): Net.Datagram
  return (assert(Net.datagram(Net.udp("127.0.0.1", 0), { timeout_ns = Clock.seconds(5) })))
end

local function test_a_socket_at_port_zero_names_the_port_it_has()
  local socket <close> = bound()
  local address = socket.address
  assert(address.kind == "udp" and address.host == "127.0.0.1", address.host)
  assert(assert(address.port) > 0)
end

local function test_each_datagram_arrives_whole_with_its_sender()
  local receiver <close> = bound()
  local sender <close> = bound()
  for _, data in ipairs({ "one", "", string.rep("x", 9000), "four" }) do
    assert(sender:send(data, receiver.address))
  end
  for _, data in ipairs({ "one", "", string.rep("x", 9000), "four" }) do
    local packet = assert(receiver:receive())
    assert(packet.data == data, "a datagram of " .. tostring(#packet.data) .. " bytes")
    assert(packet.address.kind == "udp" and packet.address.host == "127.0.0.1")
    assert(packet.address.port == sender.address.port)
  end
  local none, why = receiver:receive(0)
  assert(none == nil and why == Poll.TIMEOUT, why)
end

local function test_receive_waits_no_longer_than_its_timeout()
  local socket <close> = bound()
  local started = Clock.monotonic_ns()
  local packet, why = socket:receive(Clock.ms(20))
  assert(packet == nil and why == Poll.TIMEOUT, why)
  assert(Clock.monotonic_ns() - started < Clock.seconds(4))
  socket:set_timeout(Clock.ms(20))
  local again, again_why = socket:receive()
  assert(again == nil and again_why == Poll.TIMEOUT, again_why)
  local now, now_why = socket:receive(0)
  assert(now == nil and now_why == Poll.TIMEOUT, now_why)
end

local function test_a_closed_socket_refuses_and_closes_again()
  local socket = bound()
  local to = socket.address
  assert(socket:close())
  assert(socket:close())
  local sent, send_why = socket:send("x", to)
  assert(not sent and send_why == "net: the socket is closed", send_why)
  local packet, receive_why = socket:receive()
  assert(packet == nil and receive_why == "net: the socket is closed", receive_why)
end

local function test_closing_ends_a_task_waiting_to_receive()
  Poll.run(function()
    local socket = bound()
    socket:set_timeout(nil)
    local why = ""
    local waiter = Poll.spawn(function()
      local _, trouble = socket:receive()
      why = trouble
    end)
    assert(Poll.delay(Clock.ms(10)))
    assert(socket:close())
    assert(waiter:join(Clock.seconds(5)))
    assert(why == "net: the socket is closed", why)
  end)
end

local function test_tasks_exchange_datagrams_through_a_run()
  Poll.run(function()
    local server <close> = bound()
    local client <close> = bound()
    local echo = Poll.spawn(function()
      local packet = assert(server:receive())
      assert(server:send(packet.data:upper(), packet.address))
    end)
    assert(client:send("ping", server.address))
    local packet = assert(client:receive())
    assert(packet.data == "PING" and packet.address.port == server.address.port)
    assert(echo:join())
  end)
end

local function test_a_name_is_refused_not_looked_up()
  local socket, why = Net.datagram(Net.udp("localhost", 0))
  assert(socket == nil and why:find("not a numeric IPv4 or IPv6 address", 1, true) ~= nil, why)
  local sender <close> = bound()
  local sent, send_why = sender:send("x", Net.udp("localhost", 9))
  assert(not sent and send_why:find("not a numeric IPv4 or IPv6 address", 1, true) ~= nil, send_why)
end

local function test_a_port_in_use_is_refused()
  local first <close> = bound()
  local second, why = Net.datagram(Net.udp("127.0.0.1", assert(first.address.port)))
  assert(second == nil and why:find("127.0.0.1:", 1, true) == 1, why)
end

local function test_what_is_no_datagram_raises()
  local socket <close> = bound()
  Test.raises(function() Net.datagram(Net.tcp("127.0.0.1", 0)) end, "Net.udp address")
  Test.raises(function() socket:send("x", Net.tcp("127.0.0.1", 9)) end, "Net.udp address")
  Test.raises(function() socket:send(string.rep("x", 65536), socket.address) end, "at most 65535 bytes")
  Test.raises(function() Net.datagram(Net.udp("127.0.0.1", 0), { timeout_ns = -1 }) end, "timeout_ns")
  Test.raises(function() socket:receive(-1) end, "timeout_ns")
end
