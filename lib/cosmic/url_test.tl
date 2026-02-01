#!/usr/bin/env cosmic
local url = require("cosmic.url")

local function test_encode_spaces()
  local result = url.encode("hello world")
  assert(result == "hello%20world", "expected 'hello%20world', got '" .. result .. "'")
end
test_encode_spaces()

local function test_encode_special_chars()
  local result = url.encode("a,b&c=d")
  assert(result:match("%%2C"), "expected comma to be encoded")
  assert(result:match("%%26"), "expected ampersand to be encoded")
  assert(result:match("%%3D"), "expected equals to be encoded")
end
test_encode_special_chars()

local function test_encode_unreserved_chars()
  -- Most unreserved characters should not be encoded: A-Z a-z 0-9 - _ .
  -- Note: cosmo.EscapeParam encodes ~ as %7E (conservative but valid)
  local result = url.encode("ABC-xyz_123.test")
  assert(result == "ABC-xyz_123.test", "unreserved chars should pass through, got '" .. result .. "'")
end
test_encode_unreserved_chars()

local function test_decode_percent_sequences()
  local result = url.decode("hello%20world")
  assert(result == "hello world", "expected 'hello world', got '" .. result .. "'")
end
test_decode_percent_sequences()

local function test_decode_plus_as_space()
  local result = url.decode("hello+world")
  assert(result == "hello world", "expected 'hello world', got '" .. result .. "'")
end
test_decode_plus_as_space()

local function test_decode_mixed()
  local result = url.decode("a%2Cb%26c%3Dd")
  assert(result == "a,b&c=d", "expected 'a,b&c=d', got '" .. result .. "'")
end
test_decode_mixed()

local function test_roundtrip_basic()
  local original = "hello world"
  local encoded = url.encode(original)
  local decoded = url.decode(encoded)
  assert(decoded == original, "roundtrip failed: expected '" .. original .. "', got '" .. decoded .. "'")
end
test_roundtrip_basic()

local function test_roundtrip_special()
  local original = "name=value&foo=bar"
  local encoded = url.encode(original)
  local decoded = url.decode(encoded)
  assert(decoded == original, "roundtrip failed: expected '" .. original .. "', got '" .. decoded .. "'")
end
test_roundtrip_special()

local function test_roundtrip_unicode()
  local original = "日本語テスト"
  local encoded = url.encode(original)
  local decoded = url.decode(encoded)
  assert(decoded == original, "unicode roundtrip failed")
end
test_roundtrip_unicode()

local function test_decode_invalid_trailing_percent()
  local result, err = url.decode("test%")
  assert(result == nil, "expected nil for trailing %")
  assert(err ~= nil, "expected error message")
  assert(err == "invalid percent-encoding", "expected 'invalid percent-encoding', got '" .. err .. "'")
end
test_decode_invalid_trailing_percent()

local function test_decode_invalid_single_hex()
  local result, err = url.decode("test%A")
  assert(result == nil, "expected nil for single hex digit")
  assert(err ~= nil, "expected error message")
end
test_decode_invalid_single_hex()

local function test_decode_invalid_non_hex()
  local result, err = url.decode("test%ZZ")
  assert(result == nil, "expected nil for non-hex digits")
  assert(err ~= nil, "expected error message")
end
test_decode_invalid_non_hex()

local function test_decode_empty_string()
  local result = url.decode("")
  assert(result == "", "expected empty string")
end
test_decode_empty_string()

local function test_encode_empty_string()
  local result = url.encode("")
  assert(result == "", "expected empty string")
end
test_encode_empty_string()

local function test_decode_lowercase_hex()
  local result = url.decode("%2f%3a")
  assert(result == "/:", "expected '/:' for lowercase hex, got '" .. result .. "'")
end
test_decode_lowercase_hex()

local function test_decode_uppercase_hex()
  local result = url.decode("%2F%3A")
  assert(result == "/:", "expected '/:' for uppercase hex, got '" .. result .. "'")
end
test_decode_uppercase_hex()

-- parse tests

local function test_parse_basic()
  local result = url.parse("key=value")
  assert(result.key == "value", "expected 'value', got '" .. tostring(result.key) .. "'")
end
test_parse_basic()

local function test_parse_multiple_params()
  local result = url.parse("a=1&b=2&c=3")
  assert(result.a == "1", "expected '1' for a")
  assert(result.b == "2", "expected '2' for b")
  assert(result.c == "3", "expected '3' for c")
end
test_parse_multiple_params()

local function test_parse_encoded_values()
  local result = url.parse("name=hello%20world")
  assert(result.name == "hello world", "expected 'hello world', got '" .. tostring(result.name) .. "'")
end
test_parse_encoded_values()

local function test_parse_empty_string()
  local result = url.parse("")
  local count = 0
  for _ in pairs(result) do
    count = count + 1
  end
  assert(count == 0, "expected empty table for empty string")
end
test_parse_empty_string()

local function test_parse_empty_value()
  local result = url.parse("key=")
  assert(result.key == "", "expected empty string for 'key='")
end
test_parse_empty_value()

local function test_parse_plus_as_space()
  local result = url.parse("msg=hello+world")
  assert(result.msg == "hello world", "expected 'hello world', got '" .. tostring(result.msg) .. "'")
end
test_parse_plus_as_space()

-- parse_url tests

local function test_parse_url_full()
  local result = url.parse_url("https://user:pass@example.com:8080/path?foo=1&bar=2#frag")
  assert(result.scheme == "https", "expected 'https', got '" .. tostring(result.scheme) .. "'")
  assert(result.user == "user", "expected 'user', got '" .. tostring(result.user) .. "'")
  assert(result.pass == "pass", "expected 'pass', got '" .. tostring(result.pass) .. "'")
  assert(result.host == "example.com", "expected 'example.com', got '" .. tostring(result.host) .. "'")
  assert(result.port == 8080, "expected 8080, got " .. tostring(result.port))
  assert(result.path == "/path", "expected '/path', got '" .. tostring(result.path) .. "'")
  assert(result.query == "foo=1&bar=2", "expected 'foo=1&bar=2', got '" .. tostring(result.query) .. "'")
  assert(result.fragment == "frag", "expected 'frag', got '" .. tostring(result.fragment) .. "'")
end
test_parse_url_full()

local function test_parse_url_minimal()
  local result = url.parse_url("http://example.com")
  assert(result.scheme == "http", "expected 'http', got '" .. tostring(result.scheme) .. "'")
  assert(result.host == "example.com", "expected 'example.com', got '" .. tostring(result.host) .. "'")
  assert(result.port == nil, "expected nil port, got " .. tostring(result.port))
  assert(result.path == "" or result.path == nil, "expected empty path, got '" .. tostring(result.path) .. "'")
  assert(result.query == nil, "expected nil query, got '" .. tostring(result.query) .. "'")
end
test_parse_url_minimal()

local function test_parse_url_with_path_only()
  local result = url.parse_url("http://example.com/api/v1/users")
  assert(result.scheme == "http", "expected 'http'")
  assert(result.host == "example.com", "expected 'example.com'")
  assert(result.path == "/api/v1/users", "expected '/api/v1/users', got '" .. tostring(result.path) .. "'")
end
test_parse_url_with_path_only()

local function test_parse_url_with_query_only()
  local result = url.parse_url("http://example.com?search=test")
  assert(result.query == "search=test", "expected 'search=test', got '" .. tostring(result.query) .. "'")
end
test_parse_url_with_query_only()

local function test_parse_url_with_fragment_only()
  local result = url.parse_url("http://example.com#section")
  assert(result.fragment == "section", "expected 'section', got '" .. tostring(result.fragment) .. "'")
end
test_parse_url_with_fragment_only()

-- parse_host tests

local function test_parse_host_with_port()
  local host, port = url.parse_host("example.com:8080")
  assert(host == "example.com", "expected 'example.com', got '" .. tostring(host) .. "'")
  assert(port == 8080, "expected 8080, got " .. tostring(port))
end
test_parse_host_with_port()

local function test_parse_host_without_port()
  local host, port = url.parse_host("example.com")
  assert(host == "example.com", "expected 'example.com', got '" .. tostring(host) .. "'")
  assert(port == nil, "expected nil port, got " .. tostring(port))
end
test_parse_host_without_port()

local function test_parse_host_localhost()
  local host, port = url.parse_host("localhost:3000")
  assert(host == "localhost", "expected 'localhost', got '" .. tostring(host) .. "'")
  assert(port == 3000, "expected 3000, got " .. tostring(port))
end
test_parse_host_localhost()

local function test_parse_host_ipv4()
  local host, port = url.parse_host("192.168.1.1:80")
  assert(host == "192.168.1.1", "expected '192.168.1.1', got '" .. tostring(host) .. "'")
  assert(port == 80, "expected 80, got " .. tostring(port))
end
test_parse_host_ipv4()

local function test_parse_host_ipv6_with_port()
  local host, port = url.parse_host("[::1]:8080")
  assert(host == "::1", "expected '::1', got '" .. tostring(host) .. "'")
  assert(port == 8080, "expected 8080, got " .. tostring(port))
end
test_parse_host_ipv6_with_port()

local function test_parse_host_ipv6_without_port()
  local host, port = url.parse_host("[::1]")
  assert(host == "::1", "expected '::1', got '" .. tostring(host) .. "'")
  assert(port == nil, "expected nil port, got " .. tostring(port))
end
test_parse_host_ipv6_without_port()

local function test_parse_host_empty()
  local host, port = url.parse_host("")
  assert(host == nil, "expected nil host for empty string")
  assert(port == nil, "expected nil port for empty string")
end
test_parse_host_empty()
