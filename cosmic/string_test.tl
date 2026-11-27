local String = require("cosmic.string")
local Test = require("cosmic.test")
local StringList = require("build.string_list_fixture")
local Bench = require("cosmic.bench")

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

local function test_contains_finds_plain_text_anywhere()
  assert(String.contains("build.tl", "ld.t"))
  assert(String.contains("build.tl", "build") and String.contains("build.tl", ".tl"))
  assert(not String.contains("buildxtl", ".t"))
  assert(String.contains("100%", "%") and not String.contains("abc", "[a]"))
  assert(String.contains("x", "") and String.contains("", ""))
  assert(not String.contains("", "a"))
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

local function test_cut_keeps_text_within_the_limit()
  assert(String.cut("abc", 3) == "abc")
  assert(String.cut("abc", 5) == "abc")
  assert(String.cut("abc", 2) == "ab")
  assert(String.cut("abc", 0) == "")
  assert(String.cut("", 0) == "")
end

local function test_cut_never_splits_a_character()
  -- "a", then é (2 bytes), then € (3 bytes), then 😀 (4 bytes).
  local text = "a\195\169\226\130\172\240\159\152\128"
  assert(String.cut(text, 1) == "a")
  assert(String.cut(text, 2) == "a")
  assert(String.cut(text, 3) == "a\195\169")
  assert(String.cut(text, 5) == "a\195\169")
  assert(String.cut(text, 6) == "a\195\169\226\130\172")
  assert(String.cut(text, 9) == "a\195\169\226\130\172")
  assert(String.cut(text, 10) == text)
  assert(utf8.len(String.cut(text, 8)) ~= nil)
end

local function test_cut_backs_up_past_a_stray_continuation_byte()
  assert(String.cut("ab\128c", 2) == "a")
  assert(String.cut("\128\128\128", 2) == "")
end

local function test_cut_refuses_a_negative_count()
  local ok, err = pcall(String.cut, "abc", -1)
  assert(not ok and tostring(err):find("cut%(%-1%)") ~= nil, tostring(err))
end

local function test_as_utf8_keeps_utf8_and_replaces_what_is_not()
  local text = "a\195\169\226\130\172\240\159\152\128"
  assert(String.as_utf8(text) == text)
  assert(String.as_utf8("") == "")
  local fffd = "\239\191\189"
  assert(String.as_utf8("a\255b") == "a" .. fffd .. "b")
  assert(String.as_utf8("\128") == fffd)
  -- A cut sequence, an overlong slash and a surrogate.
  assert(String.as_utf8("x\226\130") == "x" .. fffd .. fffd)
  assert(String.as_utf8("\192\175") == fffd .. fffd)
  assert(String.as_utf8("\237\160\128") == fffd .. fffd .. fffd)
  assert(utf8.len(String.as_utf8("\244\144\128\128")) ~= nil)
end

-- string.find's plain search scans for its first byte 64 and 32 bytes at
-- a step (core/bytes.h): a byte found at every offset of texts around
-- those widths is found where it is, and one not there is not.
local function test_plain_find_finds_a_byte_at_every_offset()
  for n = 0, 140 do
    local text = string.rep("a", n)
    assert(text:find("\n", 1, true) == nil, n)
    for at = 1, n do
      local with = text:sub(1, at - 1) .. "\n" .. text:sub(at + 1)
      assert(with:find("\n", 1, true) == at, ("%d of %d"):format(at, n))
      assert(with:find("\na", 1, true) == (if at < n then at else nil end), ("%d of %d"):format(at, n))
      -- From past the byte, it is not found.
      assert(with:find("\n", at + 1, true) == nil, ("%d of %d"):format(at, n))
    end
  end
  -- A first byte that matches where the rest does not is passed over,
  -- blocks before the match, and a NUL is a byte like any other.
  local near = ("\nb"):rep(40) .. "\nab"
  assert(near:find("\nab", 1, true) == 81, near:find("\nab", 1, true))
  local nul = ("\0x"):rep(40) .. "\0y"
  assert(nul:find("\0y", 1, true) == 81)
  -- A byte at 0x80 or above is found as itself.
  local high = ("a"):rep(70) .. "\255" .. ("a"):rep(3)
  assert(high:find("\255", 1, true) == 71)
end

--- Benches. Split, lines, trim and a predicate over 1 MiB of lines.
local BENCH_LINES <const> = string.rep("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\n", 16384)

local function bench_split_lines_1_mib(b: Bench.B)
  b.bytes = #BENCH_LINES
  for _ = 1, b.n do local _ = String.split(BENCH_LINES, "\n") end
end

local function bench_lines_iterate_1_mib(b: Bench.B)
  b.bytes = #BENCH_LINES
  for _ = 1, b.n do
    local count = 0
    for _ in String.lines(BENCH_LINES) do count = count + 1 end
  end
end

local function bench_trim_1_mib(b: Bench.B)
  local padded = "   " .. BENCH_LINES .. "   "
  b.bytes = #BENCH_LINES
  b.reset()
  for _ = 1, b.n do local _ = String.trim(padded) end
end

local function bench_contains_miss_1_mib(b: Bench.B)
  b.bytes = #BENCH_LINES
  for _ = 1, b.n do local _ = String.contains(BENCH_LINES, "needle") end
end
