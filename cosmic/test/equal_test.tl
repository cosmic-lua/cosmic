--- [`cosmic.test.equal`]: what a failed comparison of two texts says.

local Equal = require("cosmic.test.equal")
local Test = require("cosmic.test")

--- `equal` passes on the same text, and on a difference fails with the change as a unified diff, named and cut.
local function test_equal_shows_the_change_as_a_diff()
  Equal.equal("a\nb\n", "a\nb\n")
  local said = Test.raises(function() Equal.equal("a\nb\nc\n", "a\nB\nc\n", "the table") end, "the table differs")
  assert(said:find("--- want\n+++ got\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c", 1, true) ~= nil, said)
  local long_want: mut {string} = {}
  local long_got: mut {string} = {}
  for i = 1, 100 do
    local old_line = "old " .. tostring(i)
    local new_line = "new " .. tostring(i)
    long_want[#long_want + 1] = old_line
    long_got[#long_got + 1] = new_line
  end
  local cut = Test.raises(function()
    Equal.equal(table.concat(long_want, "\n") .. "\n", table.concat(long_got, "\n") .. "\n")
  end, "text differs")
  assert(cut:find("more diff lines", 1, true) ~= nil and cut:find("old 100", 1, true) == nil, cut)
  assert(cut:find("-old 1\n", 1, true) ~= nil, cut)
end

--- A difference the eye cannot see is spelt out, a missing final newline is said, a long line is cut, and an empty
--- name is no name.
local function test_equal_spells_out_what_the_eye_cannot_see()
  local crlf = Test.raises(function() Equal.equal("a\r\nb\n", "a\nb\n", "") end)
  assert(crlf:find("-a\\r\n+a\n", 1, true) ~= nil and crlf:find("test: text differs", 1, true) ~= nil, crlf)
  local nonewline = Test.raises(function() Equal.equal("a\n", "a") end)
  assert(nonewline:find("No newline at end of file", 1, true) ~= nil, nonewline)
  local long = Test.raises(function() Equal.equal(string.rep("x", 1000), "y") end)
  assert(long:find("bytes lost: 801]", 1, true) ~= nil and #long < 600, tostring(#long))
  local empty = Test.raises(function() Equal.equal("", "x") end)
  assert(empty:find("+x", 1, true) ~= nil, empty)
end
