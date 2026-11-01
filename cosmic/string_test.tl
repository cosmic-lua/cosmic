local String = require("cosmic.string")
local Test = require("cosmic.test")
local StringList = require("build.string_list_fixture")

local function collected(text: string): {string}
  local out: mut {string} = {}
  for line in String.lines(text) do out[#out + 1] = line end
  return out
end

local function test_split_keeps_every_piece()
  assert(StringList.same(String.split("a,b,c", ","), { "a", "b", "c" }))
  assert(StringList.same(String.split("a,", ","), { "a", "" }))
  assert(StringList.same(String.split(",a", ","), { "", "a" }))
  assert(StringList.same(String.split("", ","), { "" }))
  assert(StringList.same(String.split("a,,b", ","), { "a", "", "b" }))
end

local function test_split_separator_is_plain_text()
  assert(StringList.same(String.split("a.b.c", "."), { "a", "b", "c" }))
  assert(StringList.same(String.split("1%%2", "%%"), { "1", "2" }))
  assert(StringList.same(String.split("a::b:c", "::"), { "a", "b:c" }))
end

local function test_split_refuses_an_empty_separator()
  Test.raises(function() String.split("abc", "") end, "separator is empty")
end

local function test_lines_match_split_on_newline()
  for _, text in ipairs({ "", "a", "a\n", "a\n\nb", "\n", "a\r\nb" }) do
    assert(StringList.same(collected(text), String.split(text, "\n")), ("%q"):format(text))
  end
  assert(StringList.same(collected("a\r\nb"), { "a\r", "b" }))
end

local function test_byte_at_reads_each_byte_from_1()
  assert(String.byte_at("abc", 1) == 97)
  assert(String.byte_at("abc", 3) == 99)
  assert(String.byte_at("\0\255", 1) == 0)
  assert(String.byte_at("\0\255", 2) == 255)
end

local function test_byte_at_refuses_the_indexes_byte_would_answer_nil_or_wrap_for()
  for _, index in ipairs({ 0, -1, -3, 4, 100 }) do
    local ok, why = pcall(String.byte_at, "abc", index)
    assert(not ok, tostring(index))
    assert(tostring(why):find(("byte_at(%d) is outside the text of 3 bytes (1 to 3)"):format(index), 1, true), tostring(why))
  end
end

local function test_byte_at_counts_one_byte_in_the_singular()
  local ok, why = pcall(String.byte_at, "x", 2)
  assert(not ok)
  assert(tostring(why):find("outside the text of 1 byte (1 to 1)", 1, true), tostring(why))
end

local function test_byte_at_says_when_the_text_is_empty()
  local ok, why = pcall(String.byte_at, "", 1)
  assert(not ok)
  assert(tostring(why):find("byte_at(1) reads an empty text", 1, true), tostring(why))
end

local function test_byte_at_blames_its_caller()
  local ok, why = pcall(function(): integer
    local byte = String.byte_at("abc", 9)
    return byte
  end)
  assert(not ok)
  assert(tostring(why):find("cosmic.string_test:", 1, true), tostring(why))
end

local function test_trim_strips_whitespace_at_both_ends()
  assert(String.trim("  a b \t\n") == "a b")
  assert(String.trim("a") == "a")
  assert(String.trim(" \t\r\n ") == "")
  assert(String.trim("") == "")
  assert(String.trim("\va\f") == "a")
end

local function test_trim_is_linear_on_long_inner_whitespace()
  -- `^%s*(.-)%s*$` backtracks quadratically on a long run of inner
  -- whitespace; trim must not.
  local text = "a" .. (" "):rep(200000) .. "b "
  assert(String.trim(text) == text:sub(1, -2))
end

local function test_prefix_and_suffix_are_plain_text()
  assert(String.starts_with("build.tl", "build"))
  assert(not String.starts_with("build.tl", "."))
  assert(String.starts_with("x", "") and String.ends_with("x", ""))
  assert(String.ends_with("build.tl", ".tl"))
  assert(not String.ends_with("buildxtl", ".tl"))
  assert(not String.ends_with("tl", ".tl"))
  assert(not String.starts_with("", "a") and not String.ends_with("", "a"))
end

local function test_counted_pluralizes_all_but_one()
  assert(String.counted(1, "byte") == "1 byte")
  assert(String.counted(0, "byte") == "0 bytes")
  assert(String.counted(2, "byte") == "2 bytes")
  assert(String.counted(-1, "byte") == "-1 bytes")
end

local function test_counted_takes_an_irregular_plural()
  assert(String.counted(1, "entry", "entries") == "1 entry")
  assert(String.counted(3, "entry", "entries") == "3 entries")
  assert(String.counted(0, "entry", "entries") == "0 entries")
end
