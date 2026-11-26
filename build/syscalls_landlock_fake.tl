--- The fake of core/syscalls_landlock_test.tl, run as a [`cosmic.fake`] main. Its first argument
--- names the case and the rest are that case's words.

local Steps = require("cosmic.fake.steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  -- Ends with status `words[1]`, or 2 where it names none.
  exit = function(words: {string}): integer return math.tointeger(tonumber(words[1] or "")) or 2 end,
  -- Runs the program and words that follow; ends with 7 where it fails
  -- or cannot start.
  ["run-or-7"] = function(argv: {string}): integer
    if Steps.run(argv) ~= nil then return 7 end
    return 0
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("syscalls_landlock_fake", cases, argv)
end

return main
