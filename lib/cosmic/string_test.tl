#!/usr/bin/env cosmic
local str = require("cosmic.string")

-- capitalize tests

local function test_capitalize_basic()
  assert(str.capitalize("hello") == "Hello", "expected Hello")
  assert(str.capitalize("world") == "World", "expected World")
end
test_capitalize_basic()

local function test_capitalize_already_upper()
  assert(str.capitalize("Hello") == "Hello", "expected Hello unchanged")
  assert(str.capitalize("HELLO") == "HELLO", "expected HELLO unchanged")
end
test_capitalize_already_upper()

local function test_capitalize_empty()
  assert(str.capitalize("") == "", "expected empty string")
end
test_capitalize_empty()

local function test_capitalize_single_char()
  assert(str.capitalize("a") == "A", "expected A")
  assert(str.capitalize("A") == "A", "expected A unchanged")
end
test_capitalize_single_char()

-- upper/lower tests

local function test_upper()
  assert(str.upper("hello") == "HELLO", "expected HELLO")
  assert(str.upper("Hello World") == "HELLO WORLD", "expected HELLO WORLD")
  assert(str.upper("") == "", "expected empty string")
end
test_upper()

local function test_lower()
  assert(str.lower("HELLO") == "hello", "expected hello")
  assert(str.lower("Hello World") == "hello world", "expected hello world")
  assert(str.lower("") == "", "expected empty string")
end
test_lower()

-- trim tests

local function test_trim_basic()
  assert(str.trim("  hello  ") == "hello", "expected hello")
  assert(str.trim("hello") == "hello", "expected hello unchanged")
end
test_trim_basic()

local function test_trim_tabs_newlines()
  assert(str.trim("\t\nhello\t\n") == "hello", "expected hello")
  assert(str.trim("  \t hello \t  ") == "hello", "expected hello")
end
test_trim_tabs_newlines()

local function test_trim_empty()
  assert(str.trim("") == "", "expected empty string")
  assert(str.trim("   ") == "", "expected empty string from whitespace")
end
test_trim_empty()

local function test_trim_preserves_inner()
  assert(str.trim("  hello world  ") == "hello world", "expected hello world")
end
test_trim_preserves_inner()

-- ltrim tests

local function test_ltrim_basic()
  assert(str.ltrim("  hello  ") == "hello  ", "expected 'hello  '")
  assert(str.ltrim("hello") == "hello", "expected hello unchanged")
end
test_ltrim_basic()

local function test_ltrim_empty()
  assert(str.ltrim("") == "", "expected empty string")
  assert(str.ltrim("   ") == "", "expected empty string from whitespace")
end
test_ltrim_empty()

-- rtrim tests

local function test_rtrim_basic()
  assert(str.rtrim("  hello  ") == "  hello", "expected '  hello'")
  assert(str.rtrim("hello") == "hello", "expected hello unchanged")
end
test_rtrim_basic()

local function test_rtrim_empty()
  assert(str.rtrim("") == "", "expected empty string")
  assert(str.rtrim("   ") == "", "expected empty string from whitespace")
end
test_rtrim_empty()

-- split tests

local function test_split_basic()
  local parts = str.split("a,b,c", ",")
  assert(#parts == 3, "expected 3 parts, got " .. #parts)
  assert(parts[1] == "a", "expected 'a', got '" .. parts[1] .. "'")
  assert(parts[2] == "b", "expected 'b', got '" .. parts[2] .. "'")
  assert(parts[3] == "c", "expected 'c', got '" .. parts[3] .. "'")
end
test_split_basic()

local function test_split_empty_parts()
  local parts = str.split("a,,c", ",")
  assert(#parts == 3, "expected 3 parts, got " .. #parts)
  assert(parts[1] == "a", "expected 'a'")
  assert(parts[2] == "", "expected empty string")
  assert(parts[3] == "c", "expected 'c'")
end
test_split_empty_parts()

local function test_split_no_separator()
  local parts = str.split("hello", ",")
  assert(#parts == 1, "expected 1 part, got " .. #parts)
  assert(parts[1] == "hello", "expected 'hello'")
end
test_split_no_separator()

local function test_split_empty_string()
  local parts = str.split("", ",")
  assert(#parts == 0, "expected 0 parts, got " .. #parts)
end
test_split_empty_string()

local function test_split_empty_separator()
  local parts = str.split("abc", "")
  assert(#parts == 3, "expected 3 parts (individual chars), got " .. #parts)
  assert(parts[1] == "a", "expected 'a'")
  assert(parts[2] == "b", "expected 'b'")
  assert(parts[3] == "c", "expected 'c'")
end
test_split_empty_separator()

local function test_split_special_chars()
  local parts = str.split("a.b.c", ".")
  assert(#parts == 3, "expected 3 parts, got " .. #parts)
  assert(parts[1] == "a", "expected 'a'")
  assert(parts[2] == "b", "expected 'b'")
  assert(parts[3] == "c", "expected 'c'")
end
test_split_special_chars()

-- starts_with tests

local function test_starts_with_true()
  assert(str.starts_with("hello world", "hello"), "expected true")
  assert(str.starts_with("hello", "hello"), "expected true for exact match")
  assert(str.starts_with("hello", ""), "expected true for empty prefix")
end
test_starts_with_true()

local function test_starts_with_false()
  assert(not str.starts_with("hello world", "world"), "expected false")
  assert(not str.starts_with("hello", "hello world"), "expected false for longer prefix")
end
test_starts_with_false()

local function test_starts_with_empty()
  assert(str.starts_with("", ""), "expected true for empty string and empty prefix")
  assert(not str.starts_with("", "hello"), "expected false for empty string")
end
test_starts_with_empty()

-- ends_with tests

local function test_ends_with_true()
  assert(str.ends_with("hello world", "world"), "expected true")
  assert(str.ends_with("hello", "hello"), "expected true for exact match")
  assert(str.ends_with("hello", ""), "expected true for empty suffix")
end
test_ends_with_true()

local function test_ends_with_false()
  assert(not str.ends_with("hello world", "hello"), "expected false")
  assert(not str.ends_with("hello", "hello world"), "expected false for longer suffix")
end
test_ends_with_false()

local function test_ends_with_empty()
  assert(str.ends_with("", ""), "expected true for empty string and empty suffix")
  assert(not str.ends_with("", "hello"), "expected false for empty string")
end
test_ends_with_empty()
