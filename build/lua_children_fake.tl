--- The fake of build/lua_children_test.tl, run as a [`cosmic.fake`] main:
--- `print WORDS` prints its words.

local Steps = require("build.fake_steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  print = function(words: {string}): integer
    return Steps.print(table.concat(words, " ")) or 0
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("lua children fake", cases, argv)
end

return main
