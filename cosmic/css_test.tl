#!/usr/bin/env cosmic
local css = require("cosmic.css")

local function test_escape_preserves_alphanumerics()
  local result = css.escape("Hello123")
  assert(result == "Hello123", "expected alphanumerics untouched, got: " .. result)
end

local function test_escape_encodes_backslash()
  local result = css.escape("\\")
  assert(result == "\\5c ", "expected a hex escape for backslash, got: " .. result)
end

local function test_escape_encodes_quote()
  local result = css.escape('"')
  assert(result == "\\22 ", "expected a hex escape for the quote, got: " .. result)
end

local function test_escape_breaks_out_of_url_and_expression_syntax()
  -- '(' and ')' are what open url(...) and expression(...); both must
  -- be escaped so neither can be injected through an interpolated value.
  local result = css.escape("url(javascript:alert(1))")
  assert(not result:match("[()]"), "expected ( and ) to be escaped, got: " .. result)
end

local function test_escape_passes_utf8_continuation_bytes_through()
  -- A byte >= 0x80 can never collide with an ASCII delimiter, so it is
  -- safe (and necessary for correctness) to leave multi-byte UTF-8 text
  -- untouched rather than escaping it byte by byte.
  local result = css.escape("café")
  assert(result == "café", "expected UTF-8 text to pass through unescaped, got: " ..
    result)
end

local function test_safe_escapes_and_wraps()
  local out = css.safe('"')
  assert(out.raw == "\\22 ", "expected escaped value, got: " .. out.raw)
end

local function test_trusted_wraps_without_escaping()
  local out = css.trusted('"')
  assert(out.raw == '"', "trusted must not escape, got: " .. out.raw)
end
