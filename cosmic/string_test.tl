#!/usr/bin/env cosmic
local str = require("cosmic.string")

-- capitalize tests

local function test_capitalize_basic()
  assert(str.capitalize("hello") == "Hello", "expected Hello")
  assert(str.capitalize("world") == "World", "expected World")
end

local function test_capitalize_already_upper()
  assert(str.capitalize("Hello") == "Hello", "expected Hello unchanged")
  assert(str.capitalize("HELLO") == "HELLO", "expected HELLO unchanged")
end

local function test_capitalize_empty()
  assert(str.capitalize("") == "", "expected empty string")
end

local function test_capitalize_single_char()
  assert(str.capitalize("a") == "A", "expected A")
  assert(str.capitalize("A") == "A", "expected A unchanged")
end

-- upper/lower were removed: they duplicated Lua's string.upper/lower
-- verbatim. Use the stdlib directly.

local function test_upper_lower_removed()
  -- cast: probe removed surface
  assert((str as {string: any}).upper == nil, "str.upper should be removed")
  -- cast: probe removed surface
  assert((str as {string: any}).lower == nil, "str.lower should be removed")
end

-- trim tests

local function test_trim_basic()
  assert(str.trim("  hello  ") == "hello", "expected hello")
  assert(str.trim("hello") == "hello", "expected hello unchanged")
end

local function test_trim_tabs_newlines()
  assert(str.trim("\t\nhello\t\n") == "hello", "expected hello")
  assert(str.trim("  \t hello \t  ") == "hello", "expected hello")
end

local function test_trim_empty()
  assert(str.trim("") == "", "expected empty string")
  assert(str.trim("   ") == "", "expected empty string from whitespace")
end

local function test_trim_preserves_inner()
  assert(str.trim("  hello world  ") == "hello world", "expected hello world")
end

-- trim_left tests

local function test_ltrim_basic()
  assert(str.trim_left("  hello  ") == "hello  ", "expected 'hello  '")
  assert(str.trim_left("hello") == "hello", "expected hello unchanged")
end

local function test_ltrim_empty()
  assert(str.trim_left("") == "", "expected empty string")
  assert(str.trim_left("   ") == "", "expected empty string from whitespace")
end

-- trim_right tests

local function test_rtrim_basic()
  assert(str.trim_right("  hello  ") == "  hello", "expected '  hello'")
  assert(str.trim_right("hello") == "hello", "expected hello unchanged")
end

local function test_rtrim_empty()
  assert(str.trim_right("") == "", "expected empty string")
  assert(str.trim_right("   ") == "", "expected empty string from whitespace")
end

-- split tests

local function test_split_basic()
  local parts = str.split("a,b,c", ",")
  assert(#parts == 3, "expected 3 parts, got " .. #parts)
  assert(parts[1] == "a", "expected 'a', got '" .. parts[1] .. "'")
  assert(parts[2] == "b", "expected 'b', got '" .. parts[2] .. "'")
  assert(parts[3] == "c", "expected 'c', got '" .. parts[3] .. "'")
end

local function test_split_empty_parts()
  local parts = str.split("a,,c", ",")
  assert(#parts == 3, "expected 3 parts, got " .. #parts)
  assert(parts[1] == "a", "expected 'a'")
  assert(parts[2] == "", "expected empty string")
  assert(parts[3] == "c", "expected 'c'")
end

local function test_split_no_separator()
  local parts = str.split("hello", ",")
  assert(#parts == 1, "expected 1 part, got " .. #parts)
  assert(parts[1] == "hello", "expected 'hello'")
end

local function test_split_empty_string()
  -- one empty field, agreeing with re.split (and Go/Python)
  local parts = str.split("", ",")
  assert(#parts == 1, "expected 1 part, got " .. #parts)
  assert(parts[1] == "", "expected the one part to be empty")
end

local function test_split_empty_separator()
  local parts = str.split("abc", "")
  assert(#parts == 3, "expected 3 parts (individual chars), got " .. #parts)
  assert(parts[1] == "a", "expected 'a'")
  assert(parts[2] == "b", "expected 'b'")
  assert(parts[3] == "c", "expected 'c'")
end

local function test_split_special_chars()
  local parts = str.split("a.b.c", ".")
  assert(#parts == 3, "expected 3 parts, got " .. #parts)
  assert(parts[1] == "a", "expected 'a'")
  assert(parts[2] == "b", "expected 'b'")
  assert(parts[3] == "c", "expected 'c'")
end

local function test_split_trailing_separator()
  local parts = str.split("a,b,", ",")
  assert(#parts == 3, "expected 3 parts, got " .. #parts)
  assert(parts[1] == "a", "expected 'a'")
  assert(parts[2] == "b", "expected 'b'")
  assert(parts[3] == "", "expected empty string for trailing field")
end

local function test_split_only_separator()
  local parts = str.split(",", ",")
  assert(#parts == 2, "expected 2 parts, got " .. #parts)
  assert(parts[1] == "", "expected empty string before separator")
  assert(parts[2] == "", "expected empty string after separator")
end

local function test_split_multichar_separator()
  local parts = str.split("a::b::c", "::")
  assert(#parts == 3, "expected 3 parts, got " .. #parts)
  assert(parts[1] == "a", "expected 'a'")
  assert(parts[2] == "b", "expected 'b'")
  assert(parts[3] == "c", "expected 'c'")
end

local function test_split_multichar_trailing()
  local parts = str.split("a::b::", "::")
  assert(#parts == 3, "expected 3 parts, got " .. #parts)
  assert(parts[1] == "a", "expected 'a'")
  assert(parts[2] == "b", "expected 'b'")
  assert(parts[3] == "", "expected empty string for trailing field")
end

-- starts_with tests

local function test_starts_with_true()
  assert(str.starts_with("hello world", "hello"), "expected true")
  assert(str.starts_with("hello", "hello"), "expected true for exact match")
  assert(str.starts_with("hello", ""), "expected true for empty prefix")
end

local function test_starts_with_false()
  assert(not str.starts_with("hello world", "world"), "expected false")
  assert(not str.starts_with("hello", "hello world"), "expected false for longer prefix")
end

local function test_starts_with_empty()
  assert(str.starts_with("", ""), "expected true for empty string and empty prefix")
  assert(not str.starts_with("", "hello"), "expected false for empty string")
end

-- ends_with tests

local function test_ends_with_true()
  assert(str.ends_with("hello world", "world"), "expected true")
  assert(str.ends_with("hello", "hello"), "expected true for exact match")
  assert(str.ends_with("hello", ""), "expected true for empty suffix")
end

local function test_ends_with_false()
  assert(not str.ends_with("hello world", "hello"), "expected false")
  assert(not str.ends_with("hello", "hello world"), "expected false for longer suffix")
end

local function test_ends_with_empty()
  assert(str.ends_with("", ""), "expected true for empty string and empty suffix")
  assert(not str.ends_with("", "hello"), "expected false for empty string")
end

-- to_integer tests

local function test_to_integer_decimal()
  assert(str.to_integer("42") == 42, "expected 42")
  assert(str.to_integer("-17") == -17, "expected -17")
  assert(str.to_integer("  42  ") == 42, "expected whitespace tolerated")
end

local function test_to_integer_judges_the_value_not_the_spelling()
  assert(str.to_integer("1e3") == 1000, "expected the exponent spelling to parse")
  assert(str.to_integer("0x1F") == 31, "expected the hex spelling to parse")
end

local function test_to_integer_base()
  assert(str.to_integer("1F", 16) == 31, "expected 31")
  assert(str.to_integer("777", 8) == 511, "expected 511")
end

local function test_to_integer_hex_prefix_is_default_base_only()
  local n, err = str.to_integer("0x1F", 16)
  assert(n == nil, "expected a refusal")
  assert(err == 'not an integer in base 16: "0x1F"', "got: " .. tostring(err))
end

local function test_to_integer_refuses_non_integers()
  local fraction, fraction_err = str.to_integer("7.5")
  assert(fraction == nil, "expected a refusal for a fraction")
  assert(fraction_err == 'not an integer: "7.5"', "got: " .. tostring(fraction_err))
  local nan, nan_err = str.to_integer("nan")
  assert(nan == nil, "expected a refusal for nan")
  assert(nan_err == 'not an integer: "nan"', "got: " .. tostring(nan_err))
  local empty, empty_err = str.to_integer("")
  assert(empty == nil, "expected a refusal for the empty string")
  assert(empty_err == 'not an integer: ""', "got: " .. tostring(empty_err))
end

-- A caller hands this a value tl types as string that is nil at
-- runtime — string.match's result, which _tool/testrun.tl parses. The
-- refusal has to come back as a value, not as a throw.
local function test_to_integer_runtime_nil_refuses_rather_than_throws()
  -- cast: tl types string.match as string; it is nil at runtime
  local n, err = str.to_integer(("abc"):match("^(%d+)") as string)
  assert(n == nil, "expected a refusal")
  assert(err == "not an integer: nil", "got: " .. tostring(err))
end
