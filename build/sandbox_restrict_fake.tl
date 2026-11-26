--- The fake of cosmic/sandbox_restrict_test.tl, a [`cosmic.fake`] main
--- that a restricted child starts. Its first argument names the case and
--- the rest are that case's words.

local Steps = require("cosmic.fake.steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  print = function(words: {string}): integer
    return Steps.print(table.concat(words, " ")) or 0
  end,
  -- Sends signal `words[1]` to itself.
  signal = function(words: {string}): integer return Steps.signal(words[1]!) or 0 end,
  ["sleep-forever"] = function(_: {string}): integer return Steps.sleep_forever() end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("sandbox restrict fake", cases, argv)
end

return main
