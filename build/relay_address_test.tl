local relay_address = require("build.relay_address")

local NONE: {string} = {}

--- Whether `address` is refused on port 443 with no grants and no own
--- addresses, and the reason.
local function refused(address: string): boolean, string
  local ok, why = relay_address.check(address, 443, NONE, NONE)
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
    local ok, why = relay_address.check(address, 443, NONE, NONE)
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
    { address = "198.18.0.0", phrase = "a benchmarking address" },
    { address = "198.19.255.255", phrase = "a benchmarking address" },
  })
  expect_allowed({
    "1.0.0.0", "9.255.255.255", "11.0.0.0", "172.15.255.255", "172.32.0.0",
    "192.167.255.255", "192.169.0.0", "100.63.255.255", "100.128.0.0",
    "126.255.255.255", "128.0.0.0", "169.253.255.255", "169.255.0.0",
    "223.255.255.255", "192.0.1.255", "192.0.3.0", "198.17.255.255", "198.20.0.0",
    "198.51.99.255", "198.51.101.0", "203.0.112.255", "203.0.114.0", "8.8.8.8",
    "140.82.112.3", "93.184.216.34",
  })
end

local function test_the_metadata_addresses_are_named_though_a_range_holds_them()
  expect_refused({
    { address = "169.254.169.254", phrase = "a metadata address" },
    { address = "100.100.100.200", phrase = "a metadata address" },
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
    { address = "2001:2:0:ffff:ffff:ffff:ffff:ffff", phrase = "a benchmarking address" },
  })
  expect_allowed({
    "1::", "fe7f:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "fbff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
    "2001:db7:ffff:ffff:ffff:ffff:ffff:ffff", "2001:db9::", "3ffe:ffff::", "3fff:1000::",
    "2001:2:1::", "2001:3::", "2001:1:ffff:ffff:ffff:ffff:ffff:ffff", "2606:4700:4700::1111",
    "2a00:1450:4001:81b::200e",
  })
end

local function test_an_ipv6_address_carrying_ipv4_is_the_ipv4_it_carries()
  local carriers: {{string}} = {
    -- { prefix of the form, how a carried address is written in it }
    { "an IPv4-mapped address", "::ffff:%s" },
    { "an IPv4-compatible address", "::%s" },
    { "a NAT64 address", "64:ff9b::%s" },
  }
  local samples: {string} = {
    "10.0.0.1", "127.0.0.1", "169.254.169.254", "100.64.0.1", "224.0.0.1", "0.0.0.1",
    "8.8.8.8", "93.184.216.34",
  }
  for _, carrier in ipairs(carriers) do
    for _, v4 in ipairs(samples) do
      local address = carrier[2]:format(v4)
      if address ~= "::0.0.0.1" then
        local v4_ok = relay_address.check(v4, 443, NONE, NONE)
        local ok, why = relay_address.check(address, 443, NONE, NONE)
        assert(ok == v4_ok, address .. ": " .. why)
        if not ok then
          assert(why:find(" carrying " .. v4 .. ", ", 1, true), why)
          assert(why:find(carrier[1], 1, true), why)
        end
      end
    end
  end
end

local function test_nat64_in_a_48_carries_its_address_around_the_unused_octet()
  -- RFC 6052: 64:ff9b:1::/48, the address in bits 48-63 and 72-87.
  local no, why = refused("64:ff9b:1:a00:0:100:0:0")
  assert(no, why)
  assert(why:find("carrying 10.0.0.1, a private address", 1, true), why)
  no, why = refused("64:ff9b:1:808:8:800::")
  assert(not no, why)
  -- The octet between the halves and the tail past the address are not part of it.
  assert(not refused("64:ff9b:1:808:ff08:800:ffff:ffff"))
  assert(refused("64:ff9b:1:a00:ff00:100:ffff:ffff"))
  -- Outside the /48.
  assert(not refused("64:ff9b:2:a00:0:100:0:0"))
  assert(not refused("64:ff9a::a00:1"))
  assert(not refused("64:ff9b:0:1::a00:1"))
end

local function test_the_neighbours_of_each_embedding_prefix_carry_nothing()
  expect_refused({ { address = "::2", phrase = "carrying 0.0.0.2, an unspecified address" } })
  expect_allowed({
    "::fffe:10.0.0.1", "::ffff:1:10.0.0.1", "::1:0:10.0.0.1", "64:ff9b:0:0:1::10.0.0.1",
    "64:ff9c::10.0.0.1", "1::ffff:10.0.0.1",
  })
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
  -- 2001:1:: and 2003:: are neither.
  assert(not refused("2001:1::"))
  assert(not refused("2003::"))
  assert(not refused("2001:0100::"))
  assert(not refused("2001:1:0:0:0:0:0:1"))
end

local function test_a_literal_grant_opens_exactly_one_address_and_port()
  local grants = { "169.254.169.254:80", "[fd00:ec2::254]:*", "api.github.com:443", "10.0.0.5:8080" }
  assert(relay_address.check("169.254.169.254", 80, grants, NONE))
  local ok, why = relay_address.check("169.254.169.254", 22, grants, NONE)
  assert(not ok)
  assert(why:find("--connect 169.254.169.254:22", 1, true), why)
  assert(relay_address.check("fd00:ec2::254", 1, grants, NONE))
  assert(relay_address.check("FD00:EC2:0::254", 65535, grants, NONE))
  assert(relay_address.check("10.0.0.5", 8080, grants, NONE))
  assert(not relay_address.check("10.0.0.6", 8080, grants, NONE))
  assert(not relay_address.check("10.0.0.4", 8080, grants, NONE))
  assert(not relay_address.check("169.254.169.253", 80, grants, NONE))
  assert(not relay_address.check("fd00:ec2::255", 80, grants, NONE))
  -- A name opens no address, whatever it resolves to.
  assert(not relay_address.check("10.0.0.1", 443, { "10.0.0.1.example.com:443" }, NONE))
  -- A grant of the IPv4 address does not open the IPv6 form that carries it.
  assert(not relay_address.check("::ffff:10.0.0.5", 8080, grants, NONE))
  assert(relay_address.check("::ffff:10.0.0.5", 8080, { "[::ffff:10.0.0.5]:8080" }, NONE))
  -- An unbracketed IPv6 grant is ambiguous with host:port and names nothing.
  assert(not relay_address.check("::1", 80, { "::1:80", "::1" }, NONE))
  -- Spellings of one address are one address.
  assert(relay_address.check("::1", 80, { "[0:0:0:0:0:0:0:1]:80" }, NONE))
  assert(relay_address.check("2002:808:808::1", 80, { "[2002:0808:0808:0::1]:80" }, NONE))
end

local function test_the_hosts_own_addresses_are_refused_as_their_own()
  local own = { "203.0.113.9", "198.51.100.1", "2001:db8::1", "8.8.4.4", "2606:4700::6810:84e5" }
  local ok, why = relay_address.check("8.8.4.4", 443, NONE, own)
  assert(not ok)
  assert(why:find("8.8.4.4 is one of this host's own addresses", 1, true), why)
  assert(relay_address.check("8.8.8.8", 443, NONE, own))
  ok, why = relay_address.check("2606:4700::6810:84e5", 443, NONE, own)
  assert(not ok)
  assert(why:find("own addresses", 1, true), why)
  assert(relay_address.check("2606:4700::6810:84e6", 443, NONE, own))
  -- A form that carries one of them is that address.
  ok, why = relay_address.check("::ffff:8.8.4.4", 443, NONE, own)
  assert(not ok)
  assert(why:find("carrying 8.8.4.4, one of this host's own addresses", 1, true), why)
  ok, why = relay_address.check("64:ff9b::8.8.4.4", 443, NONE, own)
  assert(not ok)
  assert(why:find("a NAT64 address", 1, true), why)
  -- A literal grant opens it.
  assert(relay_address.check("8.8.4.4", 443, { "8.8.4.4:443" }, own))
  -- An own address that is no address is the caller's bug.
  local raised = not pcall(relay_address.check, "8.8.8.8", 443, NONE, { "eth0" })
  assert(raised)
end

local function test_a_refusal_names_the_class_and_the_remedy()
  local _, why = relay_address.check("169.254.169.254", 80, NONE, NONE)
  assert(why == "169.254.169.254 is a metadata address: grant it literally with " ..
      "--connect 169.254.169.254:80", why)
  _, why = relay_address.check("::1", 8080, NONE, NONE)
  assert(why == "::1 is a loopback address: grant it literally with --connect [::1]:8080", why)
  _, why = relay_address.check("::ffff:192.168.1.1", 22, NONE, NONE)
  assert(why == "::ffff:192.168.1.1 is an IPv4-mapped address carrying 192.168.1.1, " ..
      "a private address: grant it literally with --connect [::ffff:192.168.1.1]:22", why)
end

local function test_text_that_is_no_numeric_address_is_refused()
  for _, text in ipairs({ "", "localhost", "example.com", " 1.2.3.4", "1.2.3.4 ", "1.2.3", "1.2.3.4.5",
      "01.2.3.4", "1.2.3.256", "1.2.3.-4", "1.2.3.0x4", "0x7f.0.0.1", "2130706433", "1.2.3.4\0",
      ":", ":::", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1::2::3", "::1%eth0", "fe80::1%1",
      "g::", "12345::", ":1::", "1::2:", "1:2:3:4:5:6:7::8", "1.2.3.4::", "::1.2.3", "::1.2.3.4:5",
      "1:2:3:4:5:6:1.2.3.4:5", "::01.2.3.4", "[::1]", "::1/128", "1:2:3:4:5:6:7:8::",
      "::1:2:3:4:5:6:7:8", string.rep("1:", 30) .. "1" }) do
    local ok, why = relay_address.check(text, 80, { "x:80" }, NONE)
    assert(not ok, ("%q"):format(text))
    assert(why:find("is not a numeric address", 1, true), why)
    assert(relay_address.parse(text) == nil, ("%q"):format(text))
  end
  local ok, why = relay_address.check("a\nb\255", 80, NONE, NONE)
  assert(not ok)
  assert(why == "\"a?b?\" is not a numeric address", why)
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
  local picked, why = relay_address.select(answers, 443, NONE, NONE)
  assert(picked ~= nil and picked.address == "93.184.216.34", why)
  assert(why == "")
  -- An earlier answer a grant opens is the first allowed one.
  picked = relay_address.select(answers, 443, { "10.0.0.1:443" }, NONE)
  assert(picked ~= nil and picked.address == "10.0.0.1")
  -- The host's own address is skipped to the next.
  picked = relay_address.select(answers, 443, NONE, { "93.184.216.34" })
  assert(picked ~= nil and picked.address == "8.8.8.8")
end

local function test_selection_refuses_when_no_answer_is_allowed_and_says_why_for_each()
  local picked, why = relay_address.select({
    { address = "127.0.0.1", family = "inet" },
    { address = "::1", family = "inet6" },
    { address = "169.254.169.254", family = "inet" },
    { address = "bogus", family = "inet" },
  }, 80, NONE, NONE)
  assert(picked == nil)
  assert(why:find("127.0.0.1 is a loopback address: grant it literally with --connect 127.0.0.1:80", 1, true), why)
  assert(why:find("::1 is a loopback address", 1, true), why)
  assert(why:find("169.254.169.254 is a metadata address", 1, true), why)
  assert(why:find("\"bogus\" is not a numeric address", 1, true), why)
  picked, why = relay_address.select({}, 80, NONE, NONE)
  assert(picked == nil and why:find("no addresses", 1, true), why)
end
