local Child = require("cosmic.child")

--- A pty's streams are named by number, each once and at least one, and
--- one the pty takes names no descriptor of the caller's.
local function test_start_on_pty_refuses_what_could_name_a_terminal_of_the_callers()
  local function raises(opts: Child.Options, streams: {integer}, why: string)
    local ok, trouble = pcall(Child.start_on_pty, { "/bin/true" }, opts, { streams = streams })
    assert(not ok and tostring(trouble):find(why, 1, true), tostring(trouble))
  end
  raises({ stdin = "null" }, { 0 }, "takes no stdin")
  raises({ input = "x" }, { 0 }, "takes no stdin")
  raises({ stdout = "null" }, { 1 }, "takes no stdin")
  raises({ stderr = "null" }, { 2 }, "takes no stdin")
  raises({}, {}, "at least one stream")
  raises({}, { 0, 0 }, "each of 0, 1 and 2 once")
  raises({}, { 3 }, "each of 0, 1 and 2 once")
end
