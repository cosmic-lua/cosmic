--- The fake of cosmic/proc_tool_test.tl, run as a [`cosmic.fake`] main. Its first argument
--- names the case and the rest are that case's words.

local Steps = require("build.fake_steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  -- Ends with status `words[1]`, or 2 where it names none.
  exit = function(words: {string}): integer return math.tointeger(tonumber(words[1])) or 2 end,
  ["status-field"] = function(words: {string}): integer
    return Steps.status_field(words[1]!) or 0
  end,
  ["env-of"] = function(words: {string}): integer return Steps.env_of(words[1]!) or 0 end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("proc_tool_fake", cases, argv)
end

return main
