--- Examples for the cosmic.string module.
--- Demonstrates the plain-text search and splitting helpers and the
--- integer parser. Examples print their results so the output stays
--- deterministic.

-- Example_split_and_join demonstrates plain-text splitting: the
-- separator is literal text, never a Lua pattern, so a separator made
-- of magic characters splits on itself.
local function Example_split_and_join()
  local str = require("cosmic.string")
  local parts = str.split("a.b.c", ".")
  print(#parts)
  print(table.concat(parts, "/"))
  -- Output:
  -- 3
  -- a/b/c
end

-- Example_to_integer demonstrates parsing text as an integer. The rule
-- is the VALUE, not the spelling: an exponent or a hex prefix parses
-- when it names a whole number, and a fraction is refused rather than
-- truncated.
local function Example_to_integer()
  local check = require("cosmic.check")
  local str = require("cosmic.string")
  print(check.must(str.to_integer("42")))
  print(check.must(str.to_integer("1e3")))
  print(check.must(str.to_integer("1F", 16)))
  local n, err = str.to_integer("7.5")
  print(n, err)
  -- Output:
  -- 42
  -- 1000
  -- 31
  -- nil	not an integer: "7.5"
end

-- Suppress unused warnings for examples
local _ = {Example_split_and_join, Example_to_integer}
