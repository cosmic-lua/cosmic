local Nearby = require("cosmic.internal.nearby")

--- Whether a program's query from `host` is answered to it.
local function near(host: string): boolean
  return Nearby.reply(host, 49152, 5353) == "source"
end

local function test_loopback_link_local_and_private_addresses_are_near()
  for _, host in ipairs({ "127.0.0.1", "127.9.8.7", "10.0.0.1", "169.254.3.4", "172.16.0.1", "172.31.255.255",
      "192.168.1.20" }) do
    assert(near(host), host)
  end
end

local function test_routed_addresses_are_not_near()
  for _, host in ipairs({ "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "169.253.0.1", "100.64.0.1",
      "224.0.0.251", "0.0.0.0" }) do
    assert(not near(host), host)
  end
end

local function test_a_spelling_other_than_four_decimal_octets_is_not_near()
  for _, host in ipairs({ "", "10.1", "10.0.0.256", "010.0.0.1", "10.0.0.1.5", "0x7f.0.0.1", "::1", "10.0.0.1 " }) do
    assert(not near(host), host)
  end
end

local function test_a_member_is_answered_to_the_group_and_a_program_nearby_to_itself()
  assert(Nearby.reply("203.0.113.9", 5353, 5353) == "group", "a member, wherever it is")
  assert(Nearby.reply("192.168.1.20", 49152, 5353) == "source")
  assert(Nearby.reply("127.0.0.1", 49152, 5353) == "source")
  assert(Nearby.reply("203.0.113.9", 49152, 5353) == "none", "a far source draws nothing")
  assert(Nearby.reply("100.64.0.1", 49152, 5353) == "none")
  assert(Nearby.reply(nil, 49152, 5353) == "none")
end
