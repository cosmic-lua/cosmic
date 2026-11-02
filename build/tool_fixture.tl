--- What the tests of a verb that start this program share: a run of
--- `cosmic <words>` from a directory, and how it ended. Test support. The
--- sandbox tool tests pass descriptors and need 60 s: they have
--- [`build.sandbox_tool_fixture`].

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local this_program = require("build.this_program")

local record tool_fixture
  --- How a run of the program ended and what it printed.
  record Ran
    code: integer
    out: string
    err: string
  end
end

--- Runs `cosmic <words>` in `dir`, feeding it `input` when given, and
--- answers how it ended. A child a signal ended has no code: -1 is none a
--- test expects.
--- @param dir the directory it starts in
--- @param words its command line after the program
--- @param input what it reads on its standard input
function tool_fixture.cosmic(dir: string, words: {string}, input?: string): tool_fixture.Ran
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", input = input,
    timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code or -1, out = result.stdout or "", err = result.stderr or "" }
end

return tool_fixture
