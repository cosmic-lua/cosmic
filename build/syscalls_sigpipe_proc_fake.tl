--- The fake of core/syscalls_sigpipe_proc_test.tl, run as a [`cosmic.fake`] main. Its first argument
--- names the case and the rest are that case's words.

local Steps = require("build.fake_steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  cat = function(words: {string}): integer return Steps.cat(words[1]!) or 0 end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("syscalls_sigpipe_proc_fake", cases, argv)
end

return main
