#!/usr/bin/env cosmic
local escape = require("cosmic.escape")

-- html tests

local function test_html_basic_tags()
  local result = escape.html("<script>alert('xss')</script>")
  assert(not result:match("<"), "expected < to be escaped")
  assert(not result:match(">"), "expected > to be escaped")
  assert(result:match("&lt;"), "expected &lt; in output")
  assert(result:match("&gt;"), "expected &gt; in output")
end
test_html_basic_tags()

local function test_html_ampersand()
  local result = escape.html("foo & bar")
  assert(result:match("&amp;"), "expected & to be escaped")
end
test_html_ampersand()

local function test_html_quotes()
  local result = escape.html('say "hello"')
  assert(not result:match('"'), "expected double quote to be escaped")
end
test_html_quotes()

local function test_html_preserves_safe_chars()
  local result = escape.html("Hello, World!")
  assert(result:match("Hello"), "expected Hello to be preserved")
  assert(result:match("World"), "expected World to be preserved")
end
test_html_preserves_safe_chars()

local function test_html_empty_string()
  local result = escape.html("")
  assert(result == "", "expected empty string")
end
test_html_empty_string()

-- host tests

local function test_host_basic()
  local result = escape.host("example.com")
  assert(result == "example.com", "expected 'example.com', got '" .. result .. "'")
end
test_host_basic()

local function test_host_with_subdomain()
  local result = escape.host("api.example.com")
  assert(result == "api.example.com", "expected 'api.example.com', got '" .. result .. "'")
end
test_host_with_subdomain()

-- path tests

local function test_path_basic()
  local result = escape.path("/api/users")
  assert(result == "/api/users", "expected '/api/users', got '" .. result .. "'")
end
test_path_basic()

local function test_path_with_spaces()
  local result = escape.path("/my files/doc")
  assert(result:match("%%20") or result:match("%+"), "expected space to be encoded")
end
test_path_with_spaces()

local function test_path_preserves_slashes()
  local result = escape.path("/a/b/c")
  assert(result == "/a/b/c", "expected slashes to be preserved, got '" .. result .. "'")
end
test_path_preserves_slashes()

-- segment tests

local function test_segment_escapes_slash()
  local result = escape.segment("foo/bar")
  assert(result:match("%%2F") or result:match("%%2f"), "expected / to be encoded, got '" .. result .. "'")
end
test_segment_escapes_slash()

local function test_segment_basic()
  local result = escape.segment("users")
  assert(result == "users", "expected 'users', got '" .. result .. "'")
end
test_segment_basic()

-- fragment tests

local function test_fragment_basic()
  local result = escape.fragment("section-1")
  assert(result == "section-1", "expected 'section-1', got '" .. result .. "'")
end
test_fragment_basic()

local function test_fragment_with_spaces()
  local result = escape.fragment("section 1")
  assert(result:match("%%20") or result:match("%+"), "expected space to be encoded")
end
test_fragment_with_spaces()

-- literal tests

local function test_literal_basic()
  local result = escape.literal("test")
  assert(result == "test", "expected 'test', got '" .. result .. "'")
end
test_literal_basic()

-- user tests

local function test_user_basic()
  local result = escape.user("username")
  assert(result == "username", "expected 'username', got '" .. result .. "'")
end
test_user_basic()

local function test_user_with_special_chars()
  local result = escape.user("user@domain")
  assert(result:match("%%40") or result:match("%%2540"), "expected @ to be encoded")
end
test_user_with_special_chars()

-- pass tests

local function test_pass_basic()
  local result = escape.pass("secret123")
  assert(result == "secret123", "expected 'secret123', got '" .. result .. "'")
end
test_pass_basic()

local function test_pass_with_special_chars()
  local result = escape.pass("p@ss:word")
  assert(result:match("%%"), "expected special chars to be encoded")
end
test_pass_with_special_chars()

-- ip tests

local function test_ip_ipv4()
  local result = escape.ip("192.168.1.1")
  assert(result == "192.168.1.1", "expected '192.168.1.1', got '" .. result .. "'")
end
test_ip_ipv4()

local function test_ip_ipv6()
  local result = escape.ip("::1")
  -- IPv6 addresses may be wrapped in brackets
  assert(result:match("::1") or result:match("%%3A"), "expected ipv6 to be handled, got '" .. result .. "'")
end
test_ip_ipv6()
