local relay_address = require("cosmic.relay_address")

local NONE: {string} = {}
local NO_OWN: {{integer}} = {}

--- Whether `address` is refused on port 443 with no grants and no own
--- addresses, and the reason.
local function refused(address: string): boolean, string
  local ok, why = relay_address.check(address, 443, NONE, NO_OWN)
  return not ok, why
end

local function bytes_of(address: string): {integer}
  return assert(relay_address.parse(address))
end

local record Row
  address: string
  phrase: string
end

local function expect_refused(rows: {Row})
  for _, row in ipairs(rows) do
    local no, why = refused(row.address)
    assert(no, row.address .. " should be refused")
    assert(why:find(row.address, 1, true) == 1, why)
    assert(why:find(row.phrase, 1, true), row.address .. ": " .. why)
  end
end

local function expect_allowed(addresses: {string})
  for _, address in ipairs(addresses) do
    local ok, why = relay_address.check(address, 443, NONE, NO_OWN)
    assert(ok, address .. " should be allowed: " .. why)
    assert(why == "", why)
  end
end

local function test_each_ipv4_class_is_refused_at_both_ends_and_allowed_just_outside()
  expect_refused({
    { address = "0.0.0.0", phrase = "an unspecified address" },
    { address = "0.255.255.255", phrase = "an unspecified address" },
    { address = "10.0.0.0", phrase = "a private address" },
    { address = "10.255.255.255", phrase = "a private address" },
    { address = "172.16.0.0", phrase = "a private address" },
    { address = "172.31.255.255", phrase = "a private address" },
    { address = "192.168.0.0", phrase = "a private address" },
    { address = "192.168.255.255", phrase = "a private address" },
    { address = "100.64.0.0", phrase = "a carrier-grade NAT address" },
    { address = "100.127.255.255", phrase = "a carrier-grade NAT address" },
    { address = "127.0.0.0", phrase = "a loopback address" },
    { address = "127.255.255.255", phrase = "a loopback address" },
    { address = "169.254.0.0", phrase = "a link-local address" },
    { address = "169.254.255.255", phrase = "a link-local address" },
    { address = "224.0.0.0", phrase = "a multicast address" },
    { address = "239.255.255.255", phrase = "a multicast address" },
    { address = "240.0.0.0", phrase = "a reserved address" },
    { address = "255.255.255.254", phrase = "a reserved address" },
    { address = "255.255.255.255", phrase = "the broadcast address" },
    { address = "192.0.2.0", phrase = "a documentation address" },
    { address = "192.0.2.255", phrase = "a documentation address" },
    { address = "198.51.100.0", phrase = "a documentation address" },
    { address = "198.51.100.255", phrase = "a documentation address" },
    { address = "203.0.113.0", phrase = "a documentation address" },
    { address = "203.0.113.255", phrase = "a documentation address" },
    { address = "192.0.0.0", phrase = "a special-purpose address" },
    { address = "192.0.0.192", phrase = "a special-purpose address" },
    { address = "192.0.0.255", phrase = "a special-purpose address" },
    { address = "192.88.99.0", phrase = "a special-purpose address" },
    { address = "192.88.99.255", phrase = "a special-purpose address" },
    { address = "198.18.0.0", phrase = "a benchmarking address" },
    { address = "198.19.255.255", phrase = "a benchmarking address" },
  })
  expect_allowed({
    "1.0.0.0", "9.255.255.255", "11.0.0.0", "172.15.255.255", "172.32.0.0",
    "192.167.255.255", "192.169.0.0", "100.63.255.255", "100.128.0.0",
    "126.255.255.255", "128.0.0.0", "169.253.255.255", "169.255.0.0",
    "223.255.255.255", "192.0.1.255", "192.0.3.0", "198.17.255.255", "198.20.0.0",
    "198.51.99.255", "198.51.101.0", "192.0.1.0", "192.88.98.255", "192.88.100.0", "168.63.129.15", "168.63.129.17", "203.0.112.255", "203.0.114.0", "8.8.8.8",
    "140.82.112.3", "93.184.216.34",
  })
end

local function test_the_metadata_addresses_are_named_though_a_range_holds_them()
  expect_refused({
    { address = "169.254.169.254", phrase = "a metadata address" },
    { address = "100.100.100.200", phrase = "a metadata address" },
    { address = "168.63.129.16", phrase = "a metadata address" },
    { address = "fd00:ec2::254", phrase = "a metadata address" },
    { address = "FD00:EC2:0:0:0:0:0:254", phrase = "a metadata address" },
  })
  -- The neighbours fall to the range that holds them.
  expect_refused({
    { address = "169.254.169.253", phrase = "a link-local address" },
    { address = "100.100.100.201", phrase = "a carrier-grade NAT address" },
    { address = "fd00:ec2::255", phrase = "a private address" },
  })
end

local function test_each_ipv6_class_is_refused_at_both_ends_and_allowed_just_outside()
  expect_refused({
    { address = "::", phrase = "an unspecified address" },
    { address = "::1", phrase = "a loopback address" },
    { address = "0:0:0:0:0:0:0:1", phrase = "a loopback address" },
    { address = "fe80::", phrase = "a link-local address" },
    { address = "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff", phrase = "a link-local address" },
    { address = "fec0::", phrase = "a private address" },
    { address = "feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", phrase = "a private address" },
    { address = "fc00::", phrase = "a private address" },
    { address = "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", phrase = "a private address" },
    { address = "ff00::", phrase = "a multicast address" },
    { address = "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", phrase = "a multicast address" },
    { address = "2001:db8::", phrase = "a documentation address" },
    { address = "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff", phrase = "a documentation address" },
    { address = "3fff::", phrase = "a documentation address" },
    { address = "3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff", phrase = "a documentation address" },
    { address = "2001:2::", phrase = "a benchmarking address" },
    { address = "100::", phrase = "a discard-only address" },
    { address = "100:0:0:0:ffff:ffff:ffff:ffff", phrase = "a discard-only address" },
    { address = "5f00::", phrase = "a special-purpose address" },
    { address = "5f00:ffff:ffff:ffff:ffff:ffff:ffff:ffff", phrase = "a special-purpose address" },
    { address = "2001:1::", phrase = "a special-purpose address" },
    { address = "2001:10::", phrase = "a special-purpose address" },
    { address = "2001:20::", phrase = "a special-purpose address" },
    { address = "2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff", phrase = "a special-purpose address" },
    { address = "2001:2:0:ffff:ffff:ffff:ffff:ffff", phrase = "a benchmarking address" },
  })
  -- Everything outside 2000::/3 is refused, whatever its neighbours are.
  expect_refused({
    { address = "1::", phrase = "outside 2000::/3" },
    { address = "fe7f:ffff:ffff:ffff:ffff:ffff:ffff:ffff", phrase = "outside 2000::/3" },
    { address = "fbff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", phrase = "outside 2000::/3" },
    { address = "100:0:0:1::", phrase = "outside 2000::/3" },
    { address = "5eff:ffff::", phrase = "outside 2000::/3" },
    { address = "5f01::", phrase = "outside 2000::/3" },
    { address = "1fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", phrase = "outside 2000::/3" },
    { address = "4000::", phrase = "outside 2000::/3" },
    { address = "8000::", phrase = "outside 2000::/3" },
  })
  expect_allowed({
    "2001:db7:ffff:ffff:ffff:ffff:ffff:ffff", "2001:db9::", "3ffe:ffff::", "3fff:1000::",
    "2001:200::", "2000:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "2000::", "3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
    "2606:4700:4700::1111", "2a00:1450:4001:81b::200e",
  })
end

local function test_an_ipv6_address_carrying_ipv4_is_refused_outright_whatever_it_carries()
  local carriers: {{string}} = {
    -- { reason of the form, how a carried address is written in it }
    { "an IPv4-mapped address, which the relay does not decode", "::ffff:%s" },
    { "a NAT64 address, which the relay does not decode", "64:ff9b::%s" },
  }
  local samples: {string} = {
    "10.0.0.1", "127.0.0.1", "169.254.169.254", "100.64.0.1", "224.0.0.1", "0.0.0.1",
    "8.8.8.8", "93.184.216.34",
  }
  for _, carrier in ipairs(carriers) do
    for _, v4 in ipairs(samples) do
      local address = carrier[2]:format(v4)
      local no, why = refused(address)
      assert(no, address .. " is decoded to " .. v4)
      assert(why:find(address .. " is " .. carrier[1], 1, true), why)
      assert(not why:find("carrying", 1, true), why)
    end
  end
end

local function test_the_local_use_nat64_prefix_is_refused_whatever_follows_it()
  -- RFC 8215: an operator carves 64:ff9b:1::/48 at any RFC 6052 length, so
  -- the address it carries is not knowable; a /96 gateway sends the first
  -- of these to 169.254.169.254, and a /48 one reads the second as 10.0.0.1.
  for _, address in ipairs({ "64:ff9b:1:808:0:0:a9fe:a9fe", "64:ff9b:1:a00:0:100:0:0", "64:ff9b:1::",
      "64:ff9b:1:808:8:800::", "64:ff9b:1:ffff:ffff:ffff:ffff:ffff", "64:ff9b:1::8.8.8.8" }) do
    local no, why = refused(address)
    assert(no, address)
    assert(why:find(address .. " is a local-use NAT64 address", 1, true), why)
    assert(why:find("--connect [" .. address .. "]:443", 1, true), why)
  end
  -- The neighbours of the /48 are outside 2000::/3 like it, and the
  -- well-known /96 beside it is a NAT64 prefix of its own.
  for _, address in ipairs({ "64:ff9b:2:a00:0:100:0:0", "64:ff9b:0:1::a00:1", "64:ff9a::a00:1", "64:ff9c:1::" }) do
    local no, why = refused(address)
    assert(no and why:find("outside 2000::/3", 1, true), address .. ": " .. why)
  end
  local no, why = refused("64:ff9b::808:808")
  assert(no and why:find("a NAT64 address", 1, true), why)
end

local function test_ipv4_compatible_and_translated_forms_are_refused_outright()
  for _, address in ipairs({ "::2", "::8.8.8.8", "::1:0", "::a00:1",
      "0:0:0:0:0:0:ffff:ffff" }) do
    local no, why = refused(address)
    assert(no, address)
    assert(why:find(address .. " is an IPv4-compatible address, which the relay does not decode", 1, true), why)
  end
  -- ::1:a00:1 has its sixth group set, so it lies outside ::/96, and carries
  -- nothing: it is judged as itself, and like all below 2000::/3 refused.
  assert(refused("::1:a00:1"))
  assert(refused("::1:0:0:1"))
  -- The SIIT form 0:0:0:0:ffff:0::/96.
  for _, address in ipairs({ "::ffff:0:8.8.8.8", "::ffff:0:a00:1", "0:0:0:0:ffff:0:ffff:ffff" }) do
    local no, why = refused(address)
    assert(no, address)
    assert(why:find("an IPv4-translated (SIIT) address", 1, true), why)
  end
  -- Its neighbours carry nothing, and are outside 2000::/3.
  for _, address in ipairs({ "::ffff:1:a00:1", "::fffe:0:a00:1", "0:0:0:1:ffff:0:a00:1" }) do
    local no, why = refused(address)
    assert(no and why:find("outside 2000::/3", 1, true), address .. ": " .. why)
  end
  local no, why = refused("::ffff:10.0.0.1")
  assert(no and why:find("an IPv4-mapped address, which the relay does not decode", 1, true), why)
end

local function test_the_neighbours_of_each_embedding_prefix_carry_nothing()
  -- Outside 2000::/3, so refused as themselves and not as what they might carry.
  for _, address in ipairs({ "::fffe:10.0.0.1", "::ffff:1:10.0.0.1", "::1:0:10.0.0.1", "64:ff9b:0:0:1::10.0.0.1",
      "64:ff9c::10.0.0.1", "1::ffff:10.0.0.1" }) do
    local no, why = refused(address)
    assert(no and why:find("outside 2000::/3", 1, true), address .. ": " .. why)
  end
end

local function test_6to4_and_teredo_are_refused_outright_with_their_own_reasons()
  local no, why = refused("2002::")
  assert(no, why)
  assert(why:find("a 6to4 address", 1, true), why)
  no, why = refused("2002:808:808::1")
  assert(no, why)
  assert(why:find("6to4", 1, true) and why:find("--connect [2002:808:808::1]:443", 1, true), why)
  assert(refused("2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff"))
  no, why = refused("2001::")
  assert(no, why)
  assert(why:find("a Teredo address", 1, true), why)
  assert(refused("2001:0:ffff:ffff:ffff:ffff:ffff:ffff"))
  -- 2001::/23 is refused beyond Teredo, as an assignment of its own kind.
  no, why = refused("2001:1::")
  assert(no and why:find("a special-purpose address", 1, true), why)
  assert(refused("2001:1ff::"))
  -- 2001:200::, 2000:ffff:: and 2003:: are neither.
  assert(not refused("2001:200::"))
  assert(not refused("2000:ffff::"))
  assert(not refused("2003::"))
end

local function test_a_literal_grant_opens_exactly_one_address_and_port()
  local grants = { "169.254.169.254:80", "[fd00:ec2::254]:*", "api.github.com:443", "10.0.0.5:8080" }
  assert(relay_address.check("169.254.169.254", 80, grants, NO_OWN))
  local ok, why = relay_address.check("169.254.169.254", 22, grants, NO_OWN)
  assert(not ok)
  assert(why:find("--connect 169.254.169.254:22", 1, true), why)
  assert(relay_address.check("fd00:ec2::254", 1, grants, NO_OWN))
  assert(relay_address.check("FD00:EC2:0::254", 65535, grants, NO_OWN))
  assert(relay_address.check("10.0.0.5", 8080, grants, NO_OWN))
  assert(not relay_address.check("10.0.0.6", 8080, grants, NO_OWN))
  assert(not relay_address.check("10.0.0.4", 8080, grants, NO_OWN))
  assert(not relay_address.check("169.254.169.253", 80, grants, NO_OWN))
  assert(not relay_address.check("fd00:ec2::255", 80, grants, NO_OWN))
  -- A name opens no address, whatever it resolves to.
  assert(not relay_address.check("10.0.0.1", 443, { "10.0.0.1.example.com:443" }, NO_OWN))
  -- A grant of the IPv4 address does not open the IPv6 form that carries it.
  assert(not relay_address.check("::ffff:10.0.0.5", 8080, grants, NO_OWN))
  assert(relay_address.check("::ffff:10.0.0.5", 8080, { "[::ffff:10.0.0.5]:8080" }, NO_OWN))
  -- An unbracketed IPv6 grant is ambiguous with host:port and names nothing.
  assert(not relay_address.check("::1", 80, { "::1:80", "::1" }, NO_OWN))
  -- Spellings of one address are one address.
  assert(relay_address.check("::1", 80, { "[0:0:0:0:0:0:0:1]:80" }, NO_OWN))
  assert(relay_address.check("2002:808:808::1", 80, { "[2002:0808:0808:0::1]:80" }, NO_OWN))
end

local function test_the_hosts_own_addresses_are_refused_as_their_own()
  local own = relay_address.own_addresses({ "203.0.113.9", "198.51.100.1", "2001:db8::1", "8.8.4.4",
    "2606:4700::6810:84e5" })
  local ok, why = relay_address.check("8.8.4.4", 443, NONE, own)
  assert(not ok)
  assert(why:find("8.8.4.4 is one of this host's own addresses", 1, true), why)
  assert(relay_address.check("8.8.8.8", 443, NONE, own))
  ok, why = relay_address.check("2606:4700::6810:84e5", 443, NONE, own)
  assert(not ok)
  assert(why:find("own addresses", 1, true), why)
  assert(relay_address.check("2606:4700::6810:84e6", 443, NONE, own))
  -- A form that carries one of them is refused undecoded.
  ok, why = relay_address.check("::ffff:8.8.4.4", 443, NONE, own)
  assert(not ok)
  assert(why:find("an IPv4-mapped address, which the relay does not decode", 1, true), why)
  ok, why = relay_address.check("64:ff9b::8.8.4.4", 443, NONE, own)
  assert(not ok)
  assert(why:find("a NAT64 address", 1, true), why)
  -- A literal grant opens it.
  assert(relay_address.check("8.8.4.4", 443, { "8.8.4.4:443" }, own))
end

local function test_an_ipv4_mapped_own_address_is_the_ipv4_address()
  local own = relay_address.own_addresses({ "::ffff:1.2.3.4", "::ffff:a00:1" })
  assert(#own[1] == 4 and #own[2] == 4)
  local ok, why = relay_address.check("1.2.3.4", 80, NONE, own)
  assert(not ok)
  assert(why:find("one of this host's own addresses", 1, true), why)
  assert(not relay_address.check("::ffff:1.2.3.4", 80, NONE, own))
  assert(relay_address.check("1.2.3.5", 80, NONE, own))
end

local function test_an_own_address_that_is_no_address_raises()
  for _, bad in ipairs({ "eth0", "", "1.2.3", "fe80::1%eth0" }) do
    local ok, why = pcall(relay_address.own_addresses, { "8.8.8.8", bad })
    assert(not ok)
    assert(tostring(why):find("is not numeric", 1, true), tostring(why))
  end
  assert(#relay_address.own_addresses({}) == 0)
end

local function test_a_refusal_names_the_class_and_the_remedy()
  local _, why = relay_address.check("169.254.169.254", 80, NONE, NO_OWN)
  assert(why == "169.254.169.254 is a metadata address: grant it literally with " ..
      "--connect 169.254.169.254:80", why)
  _, why = relay_address.check("::1", 8080, NONE, NO_OWN)
  assert(why == "::1 is a loopback address: grant it literally with --connect [::1]:8080", why)
  _, why = relay_address.check("::ffff:192.168.1.1", 22, NONE, NO_OWN)
  assert(why == "::ffff:192.168.1.1 is an IPv4-mapped address, which the relay does not decode: " ..
      "grant it literally with --connect [::ffff:192.168.1.1]:22", why)
end

local function test_text_that_is_no_numeric_address_is_refused()
  for _, text in ipairs({ "", "localhost", "example.com", " 1.2.3.4", "1.2.3.4 ", "1.2.3", "1.2.3.4.5",
      "01.2.3.4", "1.2.3.256", "1.2.3.-4", "1.2.3.0x4", "0x7f.0.0.1", "2130706433", "1.2.3.4\0",
      ":", ":::", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1::2::3", "::1%eth0", "fe80::1%1",
      "g::", "12345::", ":1::", "1::2:", "1:2:3:4:5:6:7::8", "1.2.3.4::", "::1.2.3", "::1.2.3.4:5",
      "1:2:3:4:5:6:1.2.3.4:5", "::01.2.3.4", "[::1]", "::1/128", "1:2:3:4:5:6:7:8::",
      "::1:2:3:4:5:6:7:8", string.rep("1:", 30) .. "1" }) do
    local ok, why = relay_address.check(text, 80, { "x:80" }, NO_OWN)
    assert(not ok, ("%q"):format(text))
    assert(why:find("is not a numeric address", 1, true), why)
    assert(relay_address.parse(text) == nil, ("%q"):format(text))
  end
  local ok, why = relay_address.check("a\nb\255", 80, NONE, NO_OWN)
  assert(not ok)
  assert(why == "\"a?b?\" is not a numeric address", why)
end

local function test_a_not_numeric_reason_is_cut_to_64_bytes()
  local ok, why = relay_address.check(string.rep("a", 200), 80, NONE, NO_OWN)
  assert(not ok)
  assert(why == "\"" .. string.rep("a", 64) .. "...\" is not a numeric address", why)
  ok, why = relay_address.check(string.rep("a", 64), 80, NONE, NO_OWN)
  assert(why == "\"" .. string.rep("a", 64) .. "\" is not a numeric address", why)
end

local function test_the_longest_address_text_parses_and_one_more_does_not()
  local longest = "ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255"
  assert(#longest == 45)
  assert(relay_address.parse(longest) ~= nil)
  assert(relay_address.parse("0" .. longest) == nil)
  local no, why = refused(longest)
  assert(no and why:find("a multicast address", 1, true), why)
end

local function test_a_bracketed_ipv4_or_a_star_host_grant_opens_nothing()
  assert(not relay_address.check("10.0.0.1", 80, { "[10.0.0.1]:80" }, NO_OWN))
  assert(relay_address.check("10.0.0.1", 80, { "10.0.0.1:80" }, NO_OWN))
  assert(not relay_address.check("10.0.0.1", 80, { "*:80", "*:*" }, NO_OWN))
  assert(not relay_address.check("::1", 80, { "[::1]:0x50", "[::1]:", "[::1]" }, NO_OWN))
end

local function test_parsing_gives_the_bytes()
  local cases: {{string | {integer}}} = {
    { "1.2.3.4", { 1, 2, 3, 4 } },
    { "::", { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
    { "::1", { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } },
    { "1::", { 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
    { "1:2:3:4:5:6:7::", { 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 0 } },
    { "::2:3:4:5:6:7:8", { 0, 0, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8 } },
    { "ABCD:ef01:2:30:400:5000:6:7", { 0xab, 0xcd, 0xef, 0x01, 0, 2, 0, 0x30, 4, 0, 0x50, 0, 0, 6, 0, 7 } },
    { "::ffff:1.2.3.4", { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 1, 2, 3, 4 } },
    { "1:2:3:4:5:6:255.0.0.1", { 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 255, 0, 0, 1 } },
    { "1::1.2.3.4", { 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4 } },
  }
  for _, case in ipairs(cases) do
    local want = case[2] as {integer}
    assert(table.concat(bytes_of(case[1] as string), ",") == table.concat(want, ","), case[1] as string)
  end
end

local function test_selection_picks_the_first_allowed_answer_and_only_it()
  local answers: {relay_address.Answer} = {
    { address = "10.0.0.1", family = "inet" },
    { address = "2001:db8::1", family = "inet6" },
    { address = "93.184.216.34", family = "inet" },
    { address = "8.8.8.8", family = "inet" },
  }
  local picked, why = relay_address.select(answers, 443, NONE, NO_OWN)
  assert(picked ~= nil and picked.address == "93.184.216.34", why)
  assert(why == "")
  -- An earlier answer a grant opens is the first allowed one.
  picked = relay_address.select(answers, 443, { "10.0.0.1:443" }, NO_OWN)
  assert(picked ~= nil and picked.address == "10.0.0.1")
  -- The host's own address is skipped to the next.
  picked = relay_address.select(answers, 443, NONE, relay_address.own_addresses({ "93.184.216.34" }))
  assert(picked ~= nil and picked.address == "8.8.8.8")
end

local function test_selection_refuses_when_no_answer_is_allowed_and_says_why_for_each()
  local picked, why = relay_address.select({
    { address = "127.0.0.1", family = "inet" },
    { address = "::1", family = "inet6" },
    { address = "169.254.169.254", family = "inet" },
    { address = "bogus", family = "inet" },
  }, 80, NONE, NO_OWN)
  assert(picked == nil)
  assert(why:find("127.0.0.1 is a loopback address: grant it literally with --connect 127.0.0.1:80", 1, true), why)
  assert(why:find("::1 is a loopback address", 1, true), why)
  assert(why:find("169.254.169.254 is a metadata address", 1, true), why)
  assert(why:find("\"bogus\" is not a numeric address", 1, true), why)
  picked, why = relay_address.select({}, 80, NONE, NO_OWN)
  assert(picked == nil and why:find("no addresses", 1, true), why)
end

local function test_granted_names_only_a_literal_grant_of_the_address_and_port()
  local grants = { "10.0.0.1:80", "[::1]:*", "example.com:443", "*:443", "2001:db8::2:443", "[1.2.3.4]:80" }
  assert(relay_address.granted("10.0.0.1", 80, grants))
  assert(not relay_address.granted("10.0.0.1", 81, grants))
  assert(relay_address.granted("::1", 1, grants) and relay_address.granted("::0:0:0:0:0:0:1", 65535, grants))
  -- A name or "*" opens no address; neither does an unbracketed IPv6 host or a bracketed IPv4 one.
  assert(not relay_address.granted("93.184.216.34", 443, grants))
  assert(not relay_address.granted("2001:db8::2", 443, grants))
  assert(not relay_address.granted("1.2.3.4", 80, grants))
  assert(not relay_address.granted("example.com", 443, grants))
  assert(not relay_address.granted("", 80, grants))
end
