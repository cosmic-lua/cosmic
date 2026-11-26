--- The fake of core/syscalls_sigpipe_test.tl, run as a [`cosmic.fake`] main. Its first argument
--- names the case and the rest are that case's words.

local Steps = require("cosmic.fake.steps")

local int = Steps.int

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  ["write-fd"] = function(words: {string}): integer
    return Steps.write_fd(int(words[1]!), words[2]!) or 0
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("syscalls_sigpipe_fake", cases, argv)
end

return main
