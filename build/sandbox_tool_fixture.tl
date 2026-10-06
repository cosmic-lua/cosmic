--- What build/sandbox_tool_test.tl and build/sandbox_refusal_tool_test.tl
--- share: a run of `cosmic sandbox` as this program from a directory. Test
--- support.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local this_program = require("build.this_program")

local record sandbox_tool_fixture
  --- How a run of the program ended and what it printed.
  record Ran
    code: integer
    out: string
    err: string
  end
end

--- Runs `cosmic <words>` in `dir` with the descriptors `fds` handed on,
--- and answers how it ended. A root caller's program runs as a user of its
--- own, who must be able to search `dir`: a caller makes it searchable
--- first ([`build.searchable`]).
--- @param dir the directory it starts in
--- @param words its command line after the program
--- @param fds descriptors of this process to hand on, by their number there
function sandbox_tool_fixture.cosmic(dir: string, words: {string}, fds?: {integer:integer}): sandbox_tool_fixture.Ran
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60), fds = fds,
  })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code or -1, out = result.stdout or "", err = result.stderr or "" }
end

return sandbox_tool_fixture
