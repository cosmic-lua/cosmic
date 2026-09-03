#!/usr/bin/env cosmic
local js = require("cosmic.js")

local function test_escape_literal_escapes_quotes()
  local result = js.escape_literal([["]])
  assert(result == [[\"]], "expected a backslash-escaped quote, got: " .. result)
end

local function test_escape_literal_escapes_closing_script_tag()
  -- EscapeLiteral HTML-encodes too, so a literal built with it stays
  -- safe even inside a <script> block.
  local result = js.escape_literal("</script>")
  assert(not result:match("<"), "expected < to be escaped, got: " .. result)
end

local function test_escape_literal_preserves_plain_text()
  local result = js.escape_literal("hello world")
  assert(result == "hello world", "expected plain text unchanged, got: " .. result)
end

local function test_safe_escapes_and_wraps()
  local out = js.safe([["]])
  assert(out.raw == js.escape_literal([["]]), "expected escaped literal, got: " .. out.raw)
end

local function test_trusted_wraps_without_escaping()
  local out = js.trusted([["]])
  assert(out.raw == [["]], "trusted must not escape, got: " .. out.raw)
end
