--- The fake of core/promises_held_child_test.tl, run as a
--- [`cosmic.fake`] main under each sandbox the test checks. Its first
--- argument names the case and the rest are that case's words.

local Steps = require("build.fake_steps")

local int = Steps.int

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  print = function(words: {string}): integer
    return Steps.print(table.concat(words, " ")) or 0
  end,
  -- Sets limit `words[1]` to `words[2]`, then shows it.
  ["set-and-show"] = function(words: {string}): integer
    return Steps.setrlimit(words[1]!, int(words[2]!)) or Steps.rlimit(words[1]!) or 0
  end,
  -- Sets limit `words[1]` to `words[2]`, then to `words[3]`.
  ["set-twice"] = function(words: {string}): integer
    return Steps.setrlimit(words[1]!, int(words[2]!)) or Steps.setrlimit(words[1]!, int(words[3]!)) or 0
  end,
  getpgid = function(words: {string}): integer return Steps.getpgid(int(words[1]!)) or 0 end,
  connect = function(words: {string}): integer return Steps.connect(words[1]!) or 0 end,
  ["loopback-unix"] = function(words: {string}): integer
    return Steps.loopback_unix(words[1]!) or 0
  end,
  flip = function(words: {string}): integer return Steps.flip(words[1]!, words[2]!) end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("promises held child fake", cases, argv)
end

return main
