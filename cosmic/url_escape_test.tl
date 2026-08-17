#!/usr/bin/env cosmic
local url = require("cosmic.url")

local function test_escape_param_spaces()
  local result = url.escape_param("hello world")
  assert(result == "hello%20world", "expected 'hello%20world', got '" .. result .. "'")
end
test_escape_param_spaces()

local function test_escape_param_special_chars()
  local result = url.escape_param("a,b&c=d")
  assert(result:match("%%2C"), "expected comma to be encoded")
  assert(result:match("%%26"), "expected ampersand to be encoded")
  assert(result:match("%%3D"), "expected equals to be encoded")
end
test_escape_param_special_chars()

local function test_escape_param_unreserved_chars()
  -- Most unreserved characters should not be encoded: A-Z a-z 0-9 - _ .
  -- Note: cosmo.EscapeParam encodes ~ as %7E (conservative but valid)
  local result = url.escape_param("ABC-xyz_123.test")
  assert(result == "ABC-xyz_123.test", "unreserved chars should pass through, got '" .. result .. "'")
end
test_escape_param_unreserved_chars()

local function test_unescape_param_percent_sequences()
  local result = url.unescape_param("hello%20world")
  assert(result == "hello world", "expected 'hello world', got '" .. tostring(result) .. "'")
end
test_unescape_param_percent_sequences()

local function test_unescape_param_plus_as_space()
  local result = url.unescape_param("hello+world")
  assert(result == "hello world", "expected 'hello world', got '" .. tostring(result) .. "'")
end
test_unescape_param_plus_as_space()

local function test_unescape_param_mixed()
  local result = url.unescape_param("a%2Cb%26c%3Dd")
  assert(result == "a,b&c=d", "expected 'a,b&c=d', got '" .. tostring(result) .. "'")
end
test_unescape_param_mixed()

local function test_roundtrip_basic()
  local original = "hello world"
  local encoded = url.escape_param(original)
  local decoded = url.unescape_param(encoded)
  assert(decoded == original, "roundtrip failed: expected '" .. original .. "', got '" .. tostring(decoded) .. "'")
end
test_roundtrip_basic()

local function test_roundtrip_special()
  local original = "name=value&foo=bar"
  local encoded = url.escape_param(original)
  local decoded = url.unescape_param(encoded)
  assert(decoded == original, "roundtrip failed: expected '" .. original .. "', got '" .. tostring(decoded) .. "'")
end
test_roundtrip_special()

local function test_roundtrip_unicode()
  local original = "日本語テスト"
  local encoded = url.escape_param(original)
  local decoded = url.unescape_param(encoded)
  assert(decoded == original, "unicode roundtrip failed")
end
test_roundtrip_unicode()

local function test_unescape_param_invalid_trailing_percent()
  local result, err = url.unescape_param("test%")
  assert(result == nil, "expected nil for trailing %")
  assert(err ~= nil, "expected error message")
  assert(err == "invalid percent-encoding", "expected 'invalid percent-encoding', got '" .. err .. "'")
end
test_unescape_param_invalid_trailing_percent()

local function test_unescape_param_invalid_single_hex()
  local result, err = url.unescape_param("test%A")
  assert(result == nil, "expected nil for single hex digit")
  assert(err ~= nil, "expected error message")
end
test_unescape_param_invalid_single_hex()

local function test_unescape_param_invalid_non_hex()
  local result, err = url.unescape_param("test%ZZ")
  assert(result == nil, "expected nil for non-hex digits")
  assert(err ~= nil, "expected error message")
end
test_unescape_param_invalid_non_hex()

local function test_unescape_param_empty_string()
  local result = url.unescape_param("")
  assert(result == "", "expected empty string")
end
test_unescape_param_empty_string()

local function test_escape_param_empty_string()
  local result = url.escape_param("")
  assert(result == "", "expected empty string")
end
test_escape_param_empty_string()

local function test_unescape_param_lowercase_hex()
  local result = url.unescape_param("%2f%3a")
  assert(result == "/:", "expected '/:' for lowercase hex, got '" .. tostring(result) .. "'")
end
test_unescape_param_lowercase_hex()

local function test_unescape_param_uppercase_hex()
  local result = url.unescape_param("%2F%3A")
  assert(result == "/:", "expected '/:' for uppercase hex, got '" .. tostring(result) .. "'")
end
test_unescape_param_uppercase_hex()

-- escape tests

local function test_escape_host_basic()
  local result = url.escape_host("example.com")
  assert(result == "example.com", "expected 'example.com', got '" .. result .. "'")
end
test_escape_host_basic()

local function test_escape_path_basic()
  local result = url.escape_path("/api/users")
  assert(result == "/api/users", "expected '/api/users', got '" .. result .. "'")
end
test_escape_path_basic()

local function test_escape_path_with_spaces()
  local result = url.escape_path("/my files/doc")
  assert(result:match("%%20") or result:match("%+"), "expected space to be encoded")
end
test_escape_path_with_spaces()

local function test_escape_path_preserves_slashes()
  local result = url.escape_path("/a/b/c")
  assert(result == "/a/b/c", "expected slashes to be preserved, got '" .. result .. "'")
end
test_escape_path_preserves_slashes()

local function test_escape_segment_escapes_slash()
  local result = url.escape_segment("foo/bar")
  assert(result:match("%%2F") or result:match("%%2f"), "expected / to be encoded, got '" .. result .. "'")
end
test_escape_segment_escapes_slash()

local function test_escape_fragment_with_spaces()
  local result = url.escape_fragment("section 1")
  assert(result:match("%%20") or result:match("%+"), "expected space to be encoded")
end
test_escape_fragment_with_spaces()

print("all url escape tests passed")
