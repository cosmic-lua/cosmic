#!/usr/bin/env cosmic
local html = require("cosmic.html")

local function test_escape_basic_tags()
  local result = html.escape("<script>alert('xss')</script>")
  assert(not result:match("<"), "expected < to be escaped")
  assert(not result:match(">"), "expected > to be escaped")
  assert(result:match("&lt;"), "expected &lt; in output")
  assert(result:match("&gt;"), "expected &gt; in output")
end
test_escape_basic_tags()

local function test_escape_ampersand()
  local result = html.escape("foo & bar")
  assert(result:match("&amp;"), "expected & to be escaped")
end
test_escape_ampersand()

local function test_escape_quotes()
  local result = html.escape('say "hello"')
  assert(not result:match('"'), "expected double quote to be escaped")
end
test_escape_quotes()

local function test_escape_preserves_safe_chars()
  local result = html.escape("Hello, World!")
  assert(result:match("Hello"), "expected Hello to be preserved")
  assert(result:match("World"), "expected World to be preserved")
end
test_escape_preserves_safe_chars()

local function test_escape_empty_string()
  local result = html.escape("")
  assert(result == "", "expected empty string")
end
test_escape_empty_string()

-- FIX 7: single quotes must be escaped (important in HTML attribute contexts).
local function test_escape_single_quote()
  local result = html.escape("'")
  assert(result ~= "'", "single quote must be escaped, got bare '")
  -- Accept either &#39; or &apos;
  assert(result == "&#39;" or result == "&apos;",
    "single quote should become &#39; or &apos;, got: " .. result)
end
test_escape_single_quote()
