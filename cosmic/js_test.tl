#!/usr/bin/env cosmic
local js = require("cosmic.js")

local function test_escape_literal_escapes_quotes()
  local result = js.escape_literal([["]])
  assert(result == "\\u0022", "expected a \\uXXXX-escaped quote, got: " .. result)
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

local function test_escape_literal_escapes_template_literal_syntax()
  local result = js.escape_literal([[`${alert(1)}`]])
  for _, ch in ipairs({"`", "$", "{", "}"}) do
    assert(not result:find(ch, 1, true), "expected no raw " .. ch .. ", got: " .. result)
  end
  assert(
    result == "\\u0060\\u0024\\u007balert(1)\\u007d\\u0060",
    "expected fully \\uXXXX-escaped template syntax, got: " .. result
  )
end

local function test_escape_literal_escapes_target_after_literal_backslash()
  -- cosmo.EscapeLiteral doubles a literal backslash to `\\`; a naive
  -- "optional single backslash" pattern misreads the second byte of
  -- that pair as belonging to the next target character and leaves
  -- the target raw. One literal backslash ahead of each of the five
  -- targets must still fully escape the target.
  for _, ch in ipairs({"`", "$", "{", "}", [["]]}) do
    local result = js.escape_literal("\\" .. ch)
    assert(not result:find(ch, 1, true), "expected no raw " .. ch .. ", got: " .. result)
  end
end

local function test_escape_literal_escapes_backtick_after_literal_backslash()
  -- the PR's own motivating case (`${alert(1)}`), with one leading
  -- literal backslash — the reviewer's reproduced bypass.
  local result = js.escape_literal([[\`${alert(1)}`]])
  for _, ch in ipairs({"`", "$", "{", "}"}) do
    assert(not result:find(ch, 1, true), "expected no raw " .. ch .. ", got: " .. result)
  end
  assert(
    result == "\\\\\\u0060\\u0024\\u007balert(1)\\u007d\\u0060",
    "expected the leading backslash preserved and all syntax escaped, got: " .. result
  )
end

local function test_escape_literal_escapes_attribute_breakout_quotes()
  local result = js.escape_literal([[");alert(1);//]])
  assert(not result:find('"', 1, true), "expected no raw quote byte, got: " .. result)
end

local function test_escape_literal_escapes_line_separator()
  local result = js.escape_literal("\u{2028}")
  assert(result == "\\u2028", "expected \\u2028, got: " .. result)
end

local function test_safe_escapes_and_wraps()
  local out = js.safe([["]])
  assert(out.raw == js.escape_literal([["]]), "expected escaped literal, got: " .. out.raw)
end

local function test_trusted_wraps_without_escaping()
  local out = js.trusted([["]])
  assert(out.raw == [["]], "trusted must not escape, got: " .. out.raw)
end
