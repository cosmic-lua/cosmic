#!/usr/bin/env cosmic
local ip = require("cosmic.ip")

-- parse tests

local function test_parse_ipv4_basic()
  local result = ip.parse("192.168.1.1")
  assert(result == 3232235777, "expected 3232235777, got " .. tostring(result))
end
test_parse_ipv4_basic()

local function test_parse_localhost()
  local result = ip.parse("127.0.0.1")
  assert(result == 2130706433, "expected 2130706433, got " .. tostring(result))
end
test_parse_localhost()

local function test_parse_invalid_returns_negative()
  local result = ip.parse("invalid")
  assert(result == -1, "expected -1 for invalid IP, got " .. tostring(result))
end
test_parse_invalid_returns_negative()

local function test_parse_out_of_range()
  local result = ip.parse("256.1.1.1")
  assert(result == -1, "expected -1 for out-of-range IP, got " .. tostring(result))
end
test_parse_out_of_range()

-- format tests

local function test_format_basic()
  local result = ip.format(3232235777)
  assert(result == "192.168.1.1", "expected '192.168.1.1', got '" .. result .. "'")
end
test_format_basic()

local function test_format_localhost()
  local result = ip.format(2130706433)
  assert(result == "127.0.0.1", "expected '127.0.0.1', got '" .. result .. "'")
end
test_format_localhost()

local function test_format_roundtrip()
  local original = "10.0.0.1"
  local parsed = ip.parse(original)
  local formatted = ip.format(parsed)
  assert(formatted == original, "expected roundtrip to preserve '" .. original .. "', got '" .. formatted .. "'")
end
test_format_roundtrip()

-- categorize tests

local function test_categorize_loopback()
  local result = ip.categorize(ip.parse("127.0.0.1"))
  assert(result == "LOOPBACK", "expected 'LOOPBACK', got '" .. result .. "'")
end
test_categorize_loopback()

local function test_categorize_private_192()
  local result = ip.categorize(ip.parse("192.168.1.1"))
  assert(result == "PRIVATE", "expected 'PRIVATE', got '" .. result .. "'")
end
test_categorize_private_192()

local function test_categorize_private_10()
  local result = ip.categorize(ip.parse("10.0.0.1"))
  assert(result == "PRIVATE", "expected 'PRIVATE', got '" .. result .. "'")
end
test_categorize_private_10()

local function test_categorize_public()
  local result = ip.categorize(ip.parse("8.8.8.8"))
  -- Public IPs return RIR name like "ARIN"
  assert(result ~= "LOOPBACK" and result ~= "PRIVATE", "expected public category, got '" .. result .. "'")
end
test_categorize_public()

-- is_loopback tests

local function test_is_loopback_true()
  local result = ip.is_loopback(ip.parse("127.0.0.1"))
  assert(result == true, "expected true for loopback")
end
test_is_loopback_true()

local function test_is_loopback_127_255()
  local result = ip.is_loopback(ip.parse("127.255.255.255"))
  assert(result == true, "expected true for 127.255.255.255")
end
test_is_loopback_127_255()

local function test_is_loopback_false()
  local result = ip.is_loopback(ip.parse("192.168.1.1"))
  assert(result == false, "expected false for non-loopback")
end
test_is_loopback_false()

-- is_private tests

local function test_is_private_192_168()
  local result = ip.is_private(ip.parse("192.168.1.1"))
  assert(result == true, "expected true for 192.168.x.x")
end
test_is_private_192_168()

local function test_is_private_10()
  local result = ip.is_private(ip.parse("10.0.0.1"))
  assert(result == true, "expected true for 10.x.x.x")
end
test_is_private_10()

local function test_is_private_172_16()
  local result = ip.is_private(ip.parse("172.16.0.1"))
  assert(result == true, "expected true for 172.16.x.x")
end
test_is_private_172_16()

local function test_is_private_false()
  local result = ip.is_private(ip.parse("8.8.8.8"))
  assert(result == false, "expected false for public IP")
end
test_is_private_false()

-- is_public tests

local function test_is_public_true()
  local result = ip.is_public(ip.parse("8.8.8.8"))
  assert(result == true, "expected true for public IP")
end
test_is_public_true()

local function test_is_public_cloudflare()
  local result = ip.is_public(ip.parse("1.1.1.1"))
  assert(result == true, "expected true for Cloudflare DNS")
end
test_is_public_cloudflare()

local function test_is_public_false_private()
  local result = ip.is_public(ip.parse("192.168.1.1"))
  assert(result == false, "expected false for private IP")
end
test_is_public_false_private()

local function test_is_public_false_loopback()
  local result = ip.is_public(ip.parse("127.0.0.1"))
  assert(result == false, "expected false for loopback")
end
test_is_public_false_loopback()

-- resolve tests

local function test_resolve_localhost()
  local result = ip.resolve("localhost")
  assert(result == 2130706433, "expected 127.0.0.1 for localhost, got " .. tostring(result))
end
test_resolve_localhost()

-- lookup tests

local function test_lookup_localhost()
  local result, err = ip.lookup("localhost")
  assert(result == 2130706433, "expected 127.0.0.1 for localhost, got " .. tostring(result))
  assert(err == nil, "expected nil error, got " .. tostring(err))
end
test_lookup_localhost()

local function test_lookup_invalid_returns_nil()
  local result, err = ip.lookup("this.host.does.not.exist.invalid")
  assert(result == nil, "expected nil for invalid hostname, got " .. tostring(result))
  assert(err ~= nil, "expected error message for invalid hostname")
  assert(err:find("lookup failed"), "expected 'lookup failed' in error: " .. tostring(err))
end
test_lookup_invalid_returns_nil()
