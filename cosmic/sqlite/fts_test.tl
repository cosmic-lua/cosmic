#!/usr/bin/env cosmic
local sqlite = require("cosmic.sqlite")

local function test_escape_token_wraps_a_plain_token_in_quotes()
  assert(sqlite.escape_token("hello") == "\"hello\"")
end

local function test_escape_token_doubles_an_interior_quote()
  assert(sqlite.escape_token([["hi"]]) == [["""hi"""]])
end

local function test_escape_token_neutralizes_fts5_syntax_characters()
  -- Quoting makes AND / - / * / ( / ) / : / ^ read as literal text,
  -- never as FTS5 query syntax, so free-typed text can never throw a
  -- syntax error at the MATCH parser.
  for _, tok in ipairs({"AND", "-fix", "*", "(nested)", "a:b", "x^2"}) do
    local quoted = sqlite.escape_token(tok)
    assert(quoted:sub(1, 1) == "\"" and quoted:sub(-1) == "\"",
      "expected a quoted literal for " .. tok .. ", got " .. quoted)
  end
end

local function test_match_all_requires_every_token()
  assert(sqlite.match_all("hello world") == "\"hello\" \"world\"")
end

local function test_match_all_of_empty_text_is_empty()
  assert(sqlite.match_all("") == "")
  assert(sqlite.match_all("   ") == "")
end

local function test_match_any_or_joins_tokens()
  assert(sqlite.match_any("hello world") == "\"hello\" OR \"world\"")
end

local function test_match_any_of_empty_text_is_empty()
  assert(sqlite.match_any("") == "")
end

local function test_match_all_single_token_has_no_join()
  assert(sqlite.match_all("solo") == "\"solo\"")
end
