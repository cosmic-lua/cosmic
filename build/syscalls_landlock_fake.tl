--- The fake of core/syscalls_landlock_test.tl, run as a [`cosmic.fake`] main. Its first argument
--- names the case and the rest are that case's words.

local Steps = require("build.fake_steps")

local int = Steps.int

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  exit = function(words: {string}): integer return int(words[1]!) end,
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
