--- The token index of [`build.fix.typescan`].

local typescan = require("build.fix.typescan")

--- A column a million or more along its line is told from the next
--- line's columns: the tokens are made rather than lexed, since a line
--- that long costs the lexer and renderer seconds.
local function test_a_column_past_a_million_keeps_its_line()
  local s = typescan.new({
    { tk = "t", kind = "word", y = 1, x = 1000001 },
    { tk = "u", kind = "word", y = 2, x = 1 },
  })
  assert(typescan.index_at(s, 1, 1000001) == 1)
  assert(typescan.index_at(s, 2, 1) == 2)
  assert(typescan.index_at(s, 2, 1000001) == nil)
end
