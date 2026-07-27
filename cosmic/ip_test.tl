#!/usr/bin/env cosmic
local check = require("cosmic.check")
local ip = require("cosmic.ip")

--- Parse an address the test knows is valid, asserting success.
local function p(s: string): ip.Addr
  return (check.must(ip.parse(s)))
end

-- parse tests: parse returns a typed Addr (api-review-2)

local function test_parse_ipv4_basic()
  local a = p("192.168.1.1")
  assert(a:int() == 3232235777, "expected 3232235777, got " .. tostring(a:int()))
  assert(a.family == "inet", "expected family 'inet', got " .. tostring(a.family))
end
test_parse_ipv4_basic()

local function test_parse_localhost()
  local a = p("127.0.0.1")
  assert(a:int() == 2130706433, "expected 2130706433, got " .. tostring(a:int()))
end
test_parse_localhost()

local function test_parse_invalid_returns_nil()
  local result, err = ip.parse("invalid")
  assert(result == nil, "expected nil for invalid IP, got " .. tostring(result))
  assert(type(err) == "string", "expected error message, got " .. tostring(err))
end
test_parse_invalid_returns_nil()

local function test_parse_out_of_range()
  local result, err = ip.parse("256.1.1.1")
  assert(result == nil, "expected nil for out-of-range IP, got " .. tostring(result))
  assert(type(err) == "string", "expected error message, got " .. tostring(err))
end
test_parse_out_of_range()

local function test_parse_shorthand_rejected()
  -- inet_aton-style shorthand ("127.1" == 127.0.0.1 in some parsers)
  -- must be rejected: strict dotted quad only.
  local result, err = ip.parse("127.1")
  assert(result == nil, "expected nil for '127.1', got " .. tostring(result))
  assert(type(err) == "string", "expected error message, got " .. tostring(err))
end
test_parse_shorthand_rejected()

local function test_parse_five_octets_rejected()
  local result, err = ip.parse("1.2.3.4.5")
  assert(result == nil, "expected nil for '1.2.3.4.5', got " .. tostring(result))
  assert(type(err) == "string", "expected error message, got " .. tostring(err))
end
test_parse_five_octets_rejected()

local function test_parse_leading_zero_rejected()
  -- "010" reads as octal in other parsers; ambiguity is rejected outright.
  local result, err = ip.parse("010.2.3.4")
  assert(result == nil, "expected nil for leading-zero octet, got " .. tostring(result))
  assert(type(err) == "string", "expected error message, got " .. tostring(err))
end
test_parse_leading_zero_rejected()

local function test_parse_zero_octets_ok()
  local a = p("0.0.0.0")
  assert(a:int() == 0, "expected 0 for '0.0.0.0'")
end
test_parse_zero_octets_ok()

local function test_parse_ipv6_rejected_with_clear_error()
  local result, err = ip.parse("::1")
  assert(result == nil, "expected nil for IPv6 address")
  assert(err ~= nil and err:find("IPv6 not supported") ~= nil,
    "expected 'IPv6 not supported' error, got " .. tostring(err))
end
test_parse_ipv6_rejected_with_clear_error()

local function test_parse_empty_rejected()
  local result, err = ip.parse("")
  assert(result == nil, "expected nil for empty string")
  assert(type(err) == "string", "expected error message")
end
test_parse_empty_rejected()

local function test_parse_broadcast()
  -- 255.255.255.255 is a valid dotted quad, not an error sentinel.
  local a = p("255.255.255.255")
  assert(a:int() == 4294967295, "expected 4294967295, got " .. tostring(a:int()))
end
test_parse_broadcast()

-- Addr value semantics

local function test_addr_equality()
  -- Two Addrs holding the same address compare equal (__eq), however
  -- they were produced.
  assert(p("10.0.0.1") == p("10.0.0.1"), "equal addresses must be ==")
  assert(p("10.0.0.1") ~= p("10.0.0.2"), "different addresses must be ~=")
  assert(p("127.0.0.1") == ip.addr(2130706433), "parse and addr agree")
end
test_addr_equality()

local function test_addr_family()
  local a = p("8.8.8.8")
  assert(a.family == "inet", "family is 'inet' for IPv4")
  local b = ip.addr(0)
  assert(b.family == "inet", "constructed Addr carries family too")
end
test_addr_family()

-- format / tostring

local function test_format_roundtrip()
  local original = "10.0.0.1"
  local formatted = p(original):format()
  assert(formatted == original,
    "expected roundtrip to preserve '" .. original .. "', got '" .. formatted .. "'")
end
test_format_roundtrip()

local function test_addr_tostring()
  local a = p("10.0.0.1")
  assert(tostring(a) == "10.0.0.1", "expected '10.0.0.1', got '" .. tostring(a) .. "'")
end
test_addr_tostring()

-- categorize

local function test_categorize_loopback()
  local result = p("127.0.0.1"):categorize()
  assert(result == "LOOPBACK", "expected 'LOOPBACK', got '" .. result .. "'")
end
test_categorize_loopback()

local function test_categorize_private_192()
  local result = p("192.168.1.1"):categorize()
  assert(result == "PRIVATE", "expected 'PRIVATE', got '" .. result .. "'")
end
test_categorize_private_192()

local function test_categorize_private_10()
  local result = p("10.0.0.1"):categorize()
  assert(result == "PRIVATE", "expected 'PRIVATE', got '" .. result .. "'")
end
test_categorize_private_10()

local function test_categorize_public()
  local result = p("8.8.8.8"):categorize()
  -- Public IPs return RIR name like "ARIN"
  assert(result ~= "LOOPBACK" and result ~= "PRIVATE",
    "expected public category, got '" .. result .. "'")
end
test_categorize_public()

-- is_loopback

local function test_is_loopback_true()
  assert(p("127.0.0.1"):is_loopback() == true, "expected true for loopback")
  assert(p("127.255.255.255"):is_loopback() == true, "expected true for 127.255.255.255")
end
test_is_loopback_true()

local function test_is_loopback_false()
  assert(p("192.168.1.1"):is_loopback() == false, "expected false for non-loopback")
end
test_is_loopback_false()

-- is_private

local function test_is_private_ranges()
  assert(p("192.168.1.1"):is_private() == true, "expected true for 192.168.x.x")
  assert(p("10.0.0.1"):is_private() == true, "expected true for 10.x.x.x")
  assert(p("172.16.0.1"):is_private() == true, "expected true for 172.16.x.x")
  assert(p("8.8.8.8"):is_private() == false, "expected false for public IP")
end
test_is_private_ranges()

-- is_public

local function test_is_public()
  assert(p("8.8.8.8"):is_public() == true, "expected true for public IP")
  assert(p("1.1.1.1"):is_public() == true, "expected true for Cloudflare DNS")
  assert(p("192.168.1.1"):is_public() == false, "expected false for private IP")
  assert(p("127.0.0.1"):is_public() == false, "expected false for loopback")
end
test_is_public()

-- lookup tests

local function test_lookup_localhost()
  local a, err = ip.lookup("localhost")
  assert(a, "expected Addr for localhost, got nil: " .. tostring(err))
  assert(err == nil, "expected nil error, got " .. tostring(err))
  local aa = check.must(a)
  assert(aa:int() == 2130706433, "expected 127.0.0.1, got " .. tostring(aa:int()))
  assert(aa == p("127.0.0.1"), "lookup and parse agree by value")
end
test_lookup_localhost()

local function test_lookup_invalid_returns_nil()
  local a, err = ip.lookup("this.host.does.not.exist.invalid")
  assert(a == nil, "expected nil for invalid hostname")
  assert(err ~= nil, "expected error message for invalid hostname")
  assert(err:find("lookup failed"), "expected 'lookup failed' in error: " .. tostring(err))
end
test_lookup_invalid_returns_nil()

-- addr constructor (the int-to-Addr escape hatch for the C boundary)

local function test_addr_int()
  local a = ip.addr(2130706433)
  assert(a:int() == 2130706433, "expected 2130706433, got " .. tostring(a:int()))
end
test_addr_int()

local function test_addr_methods()
  local a = ip.addr(p("127.0.0.1"):int())
  assert(a:format() == "127.0.0.1", "expected '127.0.0.1', got '" .. a:format() .. "'")
  assert(a:categorize() == "LOOPBACK", "expected 'LOOPBACK', got '" .. a:categorize() .. "'")
  assert(a:is_loopback() == true, "expected loopback")
  assert(a:is_public() == false, "expected not public")
end
test_addr_methods()

local function test_lookup_returns_addr_with_methods()
  local aa = check.must(ip.lookup("localhost"))
  assert(aa:format() == "127.0.0.1", "expected '127.0.0.1', got '" .. aa:format() .. "'")
  assert(aa:is_loopback() == true, "expected loopback")
  assert(tostring(aa) == "127.0.0.1", "expected tostring '127.0.0.1'")
end
test_lookup_returns_addr_with_methods()

-- CIDR tests

local function test_cidr_parse()
  local c = check.must(ip.cidr("192.168.0.0/16"))
  assert(c:bits() == 16, "expected 16 bits")
  assert(tostring(c:network()) == "192.168.0.0", "expected network 192.168.0.0")
  assert(tostring(c) == "192.168.0.0/16", "expected tostring 192.168.0.0/16")
  assert(c:format() == "192.168.0.0/16", "expected format to match tostring")
end
test_cidr_parse()

local function test_cidr_masks_host_bits()
  local c = check.must(ip.cidr("10.1.2.3/8"))
  assert(tostring(c:network()) == "10.0.0.0", "expected host bits masked away")
  assert(tostring(c) == "10.0.0.0/8", "expected canonical form")
end
test_cidr_masks_host_bits()

local function test_cidr_netmask_broadcast_size()
  local c = check.must(ip.cidr("192.168.1.0/24"))
  assert(tostring(c:netmask()) == "255.255.255.0", "expected /24 netmask")
  assert(tostring(c:broadcast()) == "192.168.1.255", "expected broadcast")
  assert(c:size() == 256, "expected 256 addresses, got " .. tostring(c:size()))

  local host = check.must(ip.cidr("1.2.3.4/32"))
  assert(tostring(host:netmask()) == "255.255.255.255", "expected /32 netmask")
  assert(tostring(host:broadcast()) == "1.2.3.4", "expected /32 broadcast = itself")
  assert(host:size() == 1, "expected single address")

  local all = check.must(ip.cidr("0.0.0.0/0"))
  assert(tostring(all:netmask()) == "0.0.0.0", "expected /0 netmask")
  assert(tostring(all:broadcast()) == "255.255.255.255", "expected /0 broadcast")
  assert(all:size() == 4294967296, "expected 2^32 addresses")
end
test_cidr_netmask_broadcast_size()

local function test_cidr_contains()
  local c = check.must(ip.cidr("192.168.1.0/24"))
  assert(c:contains("192.168.1.1"), "expected member")
  assert(c:contains("192.168.1.0"), "expected network address contained")
  assert(c:contains("192.168.1.255"), "expected broadcast address contained")
  assert(not c:contains("192.168.2.1"), "expected non-member")
  assert(not c:contains("10.0.0.1"), "expected non-member")

  local a = assert(ip.parse("192.168.1.42"))
  assert(c:contains(a), "expected typed Addr accepted")

  local all = check.must(ip.cidr("0.0.0.0/0"))
  assert(all:contains("8.8.8.8"), "expected /0 to contain everything")

  local host = check.must(ip.cidr("1.2.3.4/32"))
  assert(host:contains("1.2.3.4"), "expected /32 to contain itself")
  assert(not host:contains("1.2.3.5"), "expected /32 to exclude neighbors")
end
test_cidr_contains()

local function test_cidr_contains_bad_string()
  local c = check.must(ip.cidr("10.0.0.0/8"))
  local ok, err = c:contains("not-an-ip")
  assert(ok == false, "expected false for unparseable address")
  assert(err ~= nil, "expected an error message")
end
test_cidr_contains_bad_string()

local function test_cidr_equality()
  local a = check.must(ip.cidr("10.0.0.0/8"))
  local b = check.must(ip.cidr("10.9.9.9/8"))
  local c = check.must(ip.cidr("10.0.0.0/9"))
  assert(a == b, "expected same masked block to compare equal")
  assert(a ~= c, "expected different prefix to differ")
end
test_cidr_equality()

local function test_cidr_invalid()
  local cases = {
    "10.0.0.0", -- no prefix
    "10.0.0.0/", -- empty prefix
    "10.0.0.0/33", -- prefix out of range
    "10.0.0.0/08", -- leading zero
    "10.0.0.0/-1", -- negative
    "10.0.0/8", -- bad address
    "300.0.0.0/8", -- bad octet
    "10.0.0.0/8/8", -- double slash
    "::1/128", -- IPv6
    "", -- empty
  }
  for _, s in ipairs(cases) do
    local c, err = ip.cidr(s)
    assert(c == nil, "expected failure for '" .. s .. "'")
    assert(err ~= nil, "expected error message for '" .. s .. "'")
  end
end
test_cidr_invalid()
