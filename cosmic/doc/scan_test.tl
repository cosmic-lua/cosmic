#!/usr/bin/env cosmic
-- test cosmic.doc.scan module

local scan = require("cosmic.doc.scan")

-- Test the two lexing defects this module exists to fix once: a
-- keyword-prefixed identifier is not mistaken for the keyword, and a
-- bare `do ... end` block gets its own nesting level.

local function test_end_time_identifier_not_truncated()
  local source = "\nlocal end_time = 2\nlocal x = end_time\nend\n"
  local body_end, next_pos = scan.find_block_end(source, 2)
  local body = source:sub(2, body_end)
  assert(body:find("local x = end_time", 1, true), "body: " .. body)
  assert(next_pos == #source, "next_pos should land right after the real end")
  assert(source:sub(next_pos, next_pos) == "\n", "next_pos should point at the trailing newline")
end
test_end_time_identifier_not_truncated()

local function test_for_prefixed_identifier_does_not_over_nest()
  local source = "\nlocal for_each = 1\nlocal y = for_each\nend\nTRAILING"
  local body_end, next_pos = scan.find_block_end(source, 2)
  local body = source:sub(2, body_end)
  assert(body:find("local y = for_each", 1, true), "body: " .. body)
  assert(not body:find("TRAILING", 1, true), "must not consume past the real end")
  -- next_pos lands right after "end"; a newline separates it from
  -- TRAILING in these fixtures.
  assert(source:sub(next_pos + 1, next_pos + #"TRAILING") == "TRAILING",
    "next_pos should point right at what follows the real end")
end
test_for_prefixed_identifier_does_not_over_nest()

local function test_bare_do_end_block_own_nesting()
  local source = "\ndo\n  local x = 1\nend\nlocal y = 2\nend\nTRAILING"
  local body_end, next_pos = scan.find_block_end(source, 2)
  local body = source:sub(2, body_end)
  assert(body:find("local y = 2", 1, true),
    "bare do-block must not be mistaken for the function's own end: " .. body)
  -- next_pos lands right after "end"; a newline separates it from
  -- TRAILING in these fixtures.
  assert(source:sub(next_pos + 1, next_pos + #"TRAILING") == "TRAILING",
    "next_pos should point right at what follows the real end")
end
test_bare_do_end_block_own_nesting()

local function test_for_do_still_counts_once()
  -- A real for/while's own `do` must NOT also open a new level -
  -- exactly one `end` closes it.
  local source = "\nfor i = 1, 10 do\n  local x = i\nend\nlocal y = 2\nend\nTRAILING"
  local body_end, next_pos = scan.find_block_end(source, 2)
  local body = source:sub(2, body_end)
  assert(body:find("local y = 2", 1, true), "body: " .. body)
  -- next_pos lands right after "end"; a newline separates it from
  -- TRAILING in these fixtures.
  assert(source:sub(next_pos + 1, next_pos + #"TRAILING") == "TRAILING",
    "next_pos should point right at what follows the real end")
end
test_for_do_still_counts_once()

local function test_nested_function_definition()
  local source = "\nlocal f = function()\n  return 1\nend\nlocal z = f()\nend\nTRAILING"
  local body_end, next_pos = scan.find_block_end(source, 2)
  local body = source:sub(2, body_end)
  assert(body:find("local z = f()", 1, true), "body: " .. body)
  -- next_pos lands right after "end"; a newline separates it from
  -- TRAILING in these fixtures.
  assert(source:sub(next_pos + 1, next_pos + #"TRAILING") == "TRAILING",
    "next_pos should point right at what follows the real end")
end
test_nested_function_definition()

local function test_skips_strings_and_comments()
  -- Keywords inside a string or a comment must not affect depth.
  local source = [[

local s = "end for while do"
-- this comment mentions end and for and while and do too
local n = 1
end
TRAILING]]
  local body_end, next_pos = scan.find_block_end(source, 2)
  local body = source:sub(2, body_end)
  assert(body:find("local n = 1", 1, true), "body: " .. body)
  -- next_pos lands right after "end"; a newline separates it from
  -- TRAILING in these fixtures.
  assert(source:sub(next_pos + 1, next_pos + #"TRAILING") == "TRAILING",
    "next_pos should point right at what follows the real end")
end
test_skips_strings_and_comments()

local function test_skips_long_strings_and_comments()
  local source = [==[

local s = [[this stays inline]]
--[[ a long comment with end for while do inside ]]
local n = 1
end
TRAILING]==]
  local body_end, next_pos = scan.find_block_end(source, 2)
  local body = source:sub(2, body_end)
  assert(body:find("local n = 1", 1, true), "body: " .. body)
  -- next_pos lands right after "end"; a newline separates it from
  -- TRAILING in these fixtures.
  assert(source:sub(next_pos + 1, next_pos + #"TRAILING") == "TRAILING",
    "next_pos should point right at what follows the real end")
end
test_skips_long_strings_and_comments()

local function test_repeat_until_closes_its_own_level()
  -- repeat/until pairs its own depth change, distinct from the
  -- function/if/for/while/do keywords that pair with `end`.
  local source = "\nrepeat\n  local x = 1\nuntil x > 0\nlocal y = 2\nend\nTRAILING"
  local body_end, next_pos = scan.find_block_end(source, 2)
  local body = source:sub(2, body_end)
  assert(body:find("local y = 2", 1, true), "body: " .. body)
  assert(source:sub(next_pos + 1, next_pos + #"TRAILING") == "TRAILING",
    "next_pos should point right at what follows the real end")
end
test_repeat_until_closes_its_own_level()

local function test_skips_escaped_quote_in_string()
  -- A backslash-escaped quote inside a string must not end the string
  -- scan early (which would then read the rest of the string as code).
  local source = [[

local s = "a \" end for while do"
local n = 1
end
TRAILING]]
  local body_end, next_pos = scan.find_block_end(source, 2)
  local body = source:sub(2, body_end)
  assert(body:find("local n = 1", 1, true), "body: " .. body)
  assert(source:sub(next_pos + 1, next_pos + #"TRAILING") == "TRAILING",
    "next_pos should point right at what follows the real end")
end
test_skips_escaped_quote_in_string()

local function test_count_lines()
  local source = "a\nb\nc\nd"
  assert(scan.count_lines(source, 1, #source) == 3, "should count 3 newlines")
  assert(scan.count_lines(source, 1, 1) == 0, "no newline in a single-char range")
end
test_count_lines()

print("All scan tests passed!")
