--- The fake of core/rlimits_child_test.tl, run as a [`cosmic.fake`] main. Its first argument
--- names the case and the rest are that case's words.

local Steps = require("cosmic.fake.steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  print = function(words: {string}): integer
    return Steps.print(table.concat(words, " ")) or 0
  end,
  -- Each limit named, a line each.
  rlimit = function(names: {string}): integer
    for _, name in ipairs(names) do
      local stopped = Steps.rlimit(name)
      if stopped ~= nil then return stopped end
    end
    return 0
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("rlimits_child_fake", cases, argv)
end

return main
