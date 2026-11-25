--- The fake of core/syscalls_session_test.tl, a [`cosmic.fake`] main a
--- confined child runs. Its first argument names the case.

local Steps = require("build.fake_steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  -- Renices its init's autogroup and says whether that held, waits, then
  -- renices its own and shows it.
  autogroup = function(_: {string}): integer
    local init = Steps.attempt(function(): integer?
      return Steps.append("/proc/1/autogroup", "19")
    end)
    return Steps.print(if init then "init-set" else "init-kept" end) or Steps.sleep(200) or
      Steps.append("/proc/self/autogroup", "19") or Steps.cat("/proc/self/autogroup") or 0
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("syscalls session fake", cases, argv)
end

return main
