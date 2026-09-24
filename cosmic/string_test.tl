local String = require("cosmic.string")

local function same(got: {string}, want: {string}): boolean
  if #got ~= #want then return false end
  for i = 1, #want do
    if got[i] ~= want[i] then return false end
  end
  return true
end

local function collected(text: string): {string}
  local out: {string} = {}
  for line in String.lines(text) do out[#out + 1] = line end
  return out
end

local function test_split_keeps_every_piece()
  assert(same(String.split("a,b,c", ","), { "a", "b", "c" }))
  assert(same(String.split("a,", ","), { "a", "" }))
  assert(same(String.split(",a", ","), { "", "a" }))
  assert(same(String.split("", ","), { "" }))
  assert(same(String.split("a,,b", ","), { "a", "", "b" }))
end

local function test_split_separator_is_plain_text()
  assert(same(String.split("a.b.c", "."), { "a", "b", "c" }))
  assert(same(String.split("1%%2", "%%"), { "1", "2" }))
  assert(same(String.split("a::b:c", "::"), { "a", "b:c" }))
end

local function test_split_refuses_an_empty_separator()
  local ok, why = pcall(String.split, "abc", "")
  assert(not ok and tostring(why):find("not empty", 1, true), tostring(why))
end

local function test_lines_match_split_on_newline()
  for _, text in ipairs({ "", "a", "a\n", "a\n\nb", "\n", "a\r\nb" }) do
    assert(same(collected(text), String.split(text, "\n")), ("%q"):format(text))
  end
  assert(same(collected("a\r\nb"), { "a\r", "b" }))
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
