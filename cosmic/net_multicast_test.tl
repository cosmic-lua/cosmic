--- Multicast over a [`Net.datagram`] socket: a group joined on the
--- loopback interface is received by each of its members, a port is
--- shared by the sockets that ask to, and [`Net.interfaces`] lists what a
--- `via` is picked from.

local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")

--- Every group is joined on the worker's own loopback, and sent to over it.
Test.policy{ loopback = { "127.0.0.1" } }

local LOOPBACK <const> = "127.0.0.1"

--- A group of the block for a site's own use (239.255.0.0/16), one for
--- each test so that none hears another's.
local function group_of(test: integer): string
  return "239.255.77." .. tostring(test)
end

--- A socket bound to `group` itself, so that it receives no other
--- group's datagrams, at `port` or one the kernel chooses, sharing it.
local function at_group(group: string, port?: integer): Net.Datagram
  return (assert(Net.datagram(Net.udp(group, port or 0), { shared = true, timeout_ns = Clock.seconds(5) })))
end

--- A socket whose multicast leaves by the loopback interface.
local function sender(): Net.Datagram
  local socket = assert(Net.datagram(Net.udp(LOOPBACK, 0), { timeout_ns = Clock.seconds(5) }))
  assert(socket:set_multicast({ via = LOOPBACK, hops = 1, loop = true }))
  return socket
end

local function test_a_member_receives_what_is_sent_to_its_group()
  local group = group_of(1)
  local member <close> = at_group(group)
  local from <close> = sender()
  local to = Net.udp(group, assert(member.address.port))
  assert(member:join(group, LOOPBACK))
  assert(from:send("to the group", to))
  local packet = assert(member:receive())
  assert(packet.data == "to the group", packet.data)
  assert(packet.address.host == LOOPBACK and packet.address.port == from.address.port)
end

local function test_a_socket_that_joined_no_group_receives_none_of_it()
  local group = group_of(2)
  local member <close> = at_group(group)
  -- At the wildcard host and the member's port, where Linux would hand it
  -- every group a socket of the machine joined.
  local bystander <close> = assert(Net.datagram(Net.udp("0.0.0.0", assert(member.address.port)), { shared = true }))
  local from <close> = sender()
  assert(member:join(group, LOOPBACK))
  assert(from:send("members only", Net.udp(group, assert(member.address.port))))
  assert(assert(member:receive()).data == "members only")
  local packet, why = bystander:receive(Clock.ms(50))
  assert(packet == nil and why == Poll.TIMEOUT, why)
end

local function test_a_socket_that_left_its_group_receives_no_more()
  local group = group_of(3)
  local member <close> = at_group(group)
  local from <close> = sender()
  local to = Net.udp(group, assert(member.address.port))
  assert(member:join(group, LOOPBACK))
  assert(from:send("before", to))
  assert(assert(member:receive()).data == "before")
  assert(member:leave(group, LOOPBACK))
  assert(from:send("after", to))
  local packet, why = member:receive(Clock.ms(50))
  assert(packet == nil and why == Poll.TIMEOUT, why)
end

local function test_sockets_sharing_a_port_each_receive_a_groups_datagram()
  local group = group_of(4)
  local first <close> = at_group(group)
  local port = assert(first.address.port)
  local second <close> = at_group(group, port)
  assert(second.address.port == port)
  local from <close> = sender()
  assert(first:join(group, LOOPBACK))
  assert(second:join(group, LOOPBACK))
  assert(from:send("to both", Net.udp(group, port)))
  assert(assert(first:receive()).data == "to both")
  assert(assert(second:receive()).data == "to both")
end

local function test_a_port_is_shared_only_where_every_socket_asks()
  local group = group_of(5)
  local shared <close> = at_group(group)
  local port = assert(shared.address.port)
  local alone, why = Net.datagram(Net.udp(group, port))
  assert(alone == nil and why:find(group .. ":" .. tostring(port) .. ": ", 1, true) == 1, why)
  local unshared <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0)))
  local late, late_why = Net.datagram(Net.udp(LOOPBACK, assert(unshared.address.port)), { shared = true })
  assert(late == nil and late_why:find(LOOPBACK .. ":", 1, true) == 1, late_why)
end

local function test_a_group_is_joined_once_and_left_once_on_an_interface()
  local group = group_of(6)
  local member <close> = at_group(group)
  assert(member:join(group, LOOPBACK))
  local again, again_why = member:join(group, LOOPBACK)
  assert(not again and again_why:find(group .. ": ", 1, true) == 1, again_why)
  assert(member:leave(group, LOOPBACK))
  local gone, gone_why = member:leave(group, LOOPBACK)
  assert(not gone and gone_why:find(group .. ": ", 1, true) == 1, gone_why)
  -- Left, it may be joined again.
  assert(member:join(group, LOOPBACK))
end

local function test_what_is_no_group_or_no_interface_is_refused()
  local member <close> = at_group(group_of(7))
  local numeric = "the group must be a numeric IPv4 or IPv6 multicast address"
  for _, group in ipairs({ "10.0.0.1", "example.test", "239.255.77.007", "" }) do
    local joined, why = member:join(group, LOOPBACK)
    assert(not joined and why:find(numeric, 1, true) ~= nil, group .. ": " .. why)
    local left, left_why = member:leave(group, LOOPBACK)
    assert(not left and left_why ~= "", group)
  end
  local named, named_why = member:join(group_of(7), "lo")
  assert(not named and named_why:find("an IPv4 interface a numeric address", 1, true) ~= nil, named_why)
  -- 192.0.2.0/24 is for documentation: no interface has an address of it.
  local nowhere, nowhere_why = member:join(group_of(7), "192.0.2.77")
  assert(not nowhere and nowhere_why:find(group_of(7) .. ": ", 1, true) == 1, nowhere_why)
  local via, via_why = member:set_multicast({ via = "192.0.2.77" })
  assert(not via and via_why:find("via 192.0.2.77: ", 1, true) == 1, via_why)
  local name, name_why = member:set_multicast({ via = "lo" })
  assert(not name and name_why:find("via lo: ", 1, true) == 1, name_why)
  -- An IPv6 group is not joined on a socket bound to an IPv4 address.
  local other, other_why = member:join("ff15::7707", 1)
  assert(not other and other_why:find("ff15::7707: ", 1, true) == 1, other_why)
end

local function test_how_a_group_is_sent_to_is_set_a_field_at_a_time()
  local group = group_of(8)
  local member <close> = at_group(group)
  local from <close> = assert(Net.datagram(Net.udp(LOOPBACK, 0), { timeout_ns = Clock.seconds(5) }))
  assert(member:join(group, LOOPBACK))
  assert(from:set_multicast({}))
  assert(from:set_multicast({ hops = 0 }))
  assert(from:set_multicast({ hops = 255 }))
  assert(from:set_multicast({ loop = false }))
  assert(from:set_multicast({ loop = true }))
  assert(from:set_multicast({ hops = 1 }))
  assert(from:set_multicast({ via = LOOPBACK }))
  assert(from:send("by the loopback", Net.udp(group, assert(member.address.port))))
  assert(assert(member:receive()).data == "by the loopback")
end

local function test_a_via_of_the_wrong_form_and_hops_out_of_range_raise()
  local socket <close> = at_group(group_of(9))
  local group = group_of(9)
  Test.raises(function() socket:join(group, 1) end, "net: via must be one of an interface's IPv4 addresses")
  Test.raises(function() socket:leave(group, 1) end, "net: via must be one of an interface's IPv4 addresses")
  Test.raises(function() socket:set_multicast({ via = 1 }) end, "net: via must be one of an interface's IPv4 addresses")
  Test.raises(function() socket:join("ff15::7709", LOOPBACK) end, "net: via must be an interface's index")
  Test.raises(function() socket:leave("ff15::7709", 0) end, "net: via must be an interface's index")
  Test.raises(function() socket:join("ff15::7709", 1 << 31) end, "net: via must be an interface's index")
  Test.raises(function() socket:set_multicast({ hops = -1 }) end, "net: hops must be from 0 to 255")
  Test.raises(function() socket:set_multicast({ hops = 256 }) end, "net: hops must be from 0 to 255")
end

local function test_a_closed_socket_joins_leaves_and_sets_nothing()
  local group = group_of(10)
  local socket = at_group(group)
  assert(socket:close())
  local joined, join_why = socket:join(group, LOOPBACK)
  assert(not joined and join_why == "net: the socket is closed", join_why)
  local left, leave_why = socket:leave(group, LOOPBACK)
  assert(not left and leave_why == "net: the socket is closed", leave_why)
  local set, set_why = socket:set_multicast({ hops = 2 })
  assert(not set and set_why == "net: the socket is closed", set_why)
end

local function test_the_interfaces_listed_hold_the_loopback_and_its_address()
  local listed, why = Net.interfaces()
  if listed == nil then
    -- TODO: assert the list on Linux too, once a sandboxed worker's filter
    -- (core/promises.c) lets getifaddrs open its netlink socket.
    Test.skip("this worker cannot list the host's interfaces: " .. why)
    return
  end
  local names: mut {string: boolean} = {}
  local loopback = false
  for _, interface in ipairs(listed) do
    assert(#interface.name > 0 and names[interface.name] == nil, "listed once: " .. interface.name)
    names[interface.name] = true
    assert(interface.index >= 1, interface.name .. " has index " .. tostring(interface.index))
    for _, address in ipairs(interface.addresses) do
      assert(address.family == "ipv4" or address.family == "ipv6", interface.name .. " " .. address.family)
      assert(address.address:find("%", 1, true) == nil, "no zone: " .. address.address)
      assert((address.address:find(":", 1, true) ~= nil) == (address.family == "ipv6"), address.address)
      if address.address == LOOPBACK then
        assert(interface.loopback and interface.up, interface.name .. " holds " .. LOOPBACK)
        loopback = true
      end
    end
  end
  assert(loopback, LOOPBACK .. " is an address of an interface")
end

--- An IPv6 group's interface is an index. Whether a datagram sent to one
--- over the loopback interface arrives depends on the host's routes, so
--- only membership is asserted.
local function test_an_ipv6_group_is_joined_and_left_by_its_interfaces_index()
  local socket, why = Net.datagram(Net.udp("::", 0), { shared = true })
  if socket == nil then
    Test.skip("this host binds no IPv6 socket: " .. why)
    return
  end
  local member <close> = socket
  -- Linux's loopback is interface 1 in every network namespace; where
  -- the interfaces are listed, the list says.
  local index = 1
  local listed = Net.interfaces()
  for _, interface in ipairs(listed or {}) do
    if interface.loopback then index = interface.index end
  end
  local group = "ff15::7711"
  assert(member:join(group, index))
  local again, again_why = member:join(group, index)
  assert(not again and again_why:find(group .. ": ", 1, true) == 1, again_why)
  assert(member:set_multicast({ via = index, hops = 1, loop = true }))
  assert(member:leave(group, index))
  local gone, gone_why = member:leave(group, index)
  assert(not gone and gone_why:find(group .. ": ", 1, true) == 1, gone_why)
  local unicast, unicast_why = member:join("fd00::1", index)
  assert(not unicast and unicast_why:find("fd00::1: ", 1, true) == 1, unicast_why)
  Test.raises(function() member:set_multicast({ via = "::1" }) end, "net: via must be an interface's index")
end
