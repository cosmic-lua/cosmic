--- The fake of the test isolation tests (those of
--- build/test_isolation_fixture.tl and build/test_isolation_tool_test.tl),
--- run as a [`cosmic.fake`] main by the tests a nested `cosmic test` runs.
--- Its first argument names the case and the rest are that case's words.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Steps = require("build.fake_steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  -- Sleeps until it is ended; its words only mark it in /proc.
  ["sleep-forever"] = function(_: {string}): integer return Steps.sleep_forever() end,
  -- Starts the program and words that follow, leaving it running.
  start = function(argv: {string}): integer return Steps.finish(Steps.start(argv) or 0) end,
  -- Waits for `go` beside its own program, then writes `done` there.
  late = function(_: {string}): integer
    local self, trouble = Proc.executable()
    if self == nil then return Steps.fail("late", tostring(trouble)) end
    local dir = Fs.dirname(self)
    return Steps.wait_for(dir .. "/go") or Steps.write(dir .. "/done", "done") or 0
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("test isolation fake", cases, argv)
end

return main
