--- The fake of core/syscalls_proc_children_test.tl, run as a [`cosmic.fake`] main. Its first argument
--- names the case and the rest are that case's words.

local Steps = require("build.fake_steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  -- Stdin to its end, to stdout.
  cat = function(_: {string}): integer return Steps.cat() or 0 end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("syscalls_proc_children_fake", cases, argv)
end

return main
