local Loopback = require("cosmic.internal.loopback")

--- 127/8 in its one spelling is loopback; a name, ::1, a port or another
--- spelling of the same number is not.
local function test_only_the_dotted_decimal_spelling_of_127_8_is_loopback()
  for _, host in ipairs({ "127.0.0.1", "127.255.255.255", "127.1.20.3" }) do
    assert(Loopback.ipv4(host), host)
  end
  for _, host in ipairs({ "localhost", "::1", "127.0.0.01", "127.0.0.256", "127.1", "0177.0.0.1", "128.0.0.1",
      "127.0.0.1:8080", "127.0.0.1.example", "*", "", "127.0.0.0001" }) do
    assert(not Loopback.ipv4(host), host)
  end
end
