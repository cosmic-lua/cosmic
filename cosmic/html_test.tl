#!/usr/bin/env cosmic
local html = require("cosmic.html")

local function test_escape_basic_tags()
  local result = html.escape("<script>alert('xss')</script>")
  assert(not result:match("<"), "expected < to be escaped")
  assert(not result:match(">"), "expected > to be escaped")
  assert(result:match("&lt;"), "expected &lt; in output")
  assert(result:match("&gt;"), "expected &gt; in output")
end

local function test_escape_ampersand()
  local result = html.escape("foo & bar")
  assert(result:match("&amp;"), "expected & to be escaped")
end

local function test_escape_quotes()
  local result = html.escape('say "hello"')
  assert(not result:match('"'), "expected double quote to be escaped")
end

local function test_escape_preserves_safe_chars()
  local result = html.escape("Hello, World!")
  assert(result:match("Hello"), "expected Hello to be preserved")
  assert(result:match("World"), "expected World to be preserved")
end

local function test_escape_empty_string()
  local result = html.escape("")
  assert(result == "", "expected empty string")
end

-- Single quotes must be escaped (important in HTML attribute contexts).
local function test_escape_single_quote()
  local result = html.escape("'")
  assert(result ~= "'", "single quote must be escaped, got bare '")
  -- Accept either &#39; or &apos;
  assert(result == "&#39;" or result == "&apos;",
    "single quote should become &#39; or &apos;, got: " .. result)
end

local function test_unescape_inverts_escape()
  local original = [[<a href="x">Tom & Jerry's</a>]]
  assert(html.unescape(html.escape(original)) == original,
    "unescape(escape(s)) must round-trip")
end

local function test_unescape_aliases_and_unknowns()
  assert(html.unescape("&apos;&#34;") == "'\"", "aliases decode")
  assert(html.unescape("&unknown;") == "&unknown;", "unknown entities pass through")
  assert(html.unescape("&amp;lt;") == "&lt;",
    "decoding must not cascade: &amp;lt; is the TEXT &lt;")
end

local function test_safe_escapes_and_wraps()
  local out = html.safe("<b>")
  assert(out.raw == "&lt;b&gt;", "expected escaped markup, got: " .. out.raw)
end

local function test_trusted_wraps_without_escaping()
  local out = html.trusted("<b>")
  assert(out.raw == "<b>", "trusted must not escape, got: " .. out.raw)
end
