local relay_address = require("cosmic.relay.address")

local Example = {}

--- A name's answers are classified one by one and the allowed ones are the
--- only ones connected to, in order; a refusal names the remedy.
function Example.permitted()
  local own = relay_address.own_addresses({ "192.0.2.7" })
  local allowed = assert(relay_address.permitted({
    { address = "169.254.169.254", family = "inet" },
    { address = "::ffff:10.0.0.1", family = "inet6" },
    { address = "93.184.216.34", family = "inet" },
  }, 443, {}, own))
  print(#allowed, allowed[1].address) -- 1 93.184.216.34

  local ok, why = relay_address.check("169.254.169.254", 80, {}, own)
  assert(not ok)
  print(why) -- 169.254.169.254 is a metadata address: grant it literally with --connect 169.254.169.254:80
  assert(relay_address.check("169.254.169.254", 80, { "169.254.169.254:80" }, own))
  assert(#relay_address.parse("::ffff:1.2.3.4") == 16) -- bytes, 4 for IPv4 and 16 for IPv6
  assert(relay_address.parse("1.2.3") == nil)
end

return Example
