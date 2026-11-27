--- What the tests of a verb that start this program share: a run of
--- `cosmic <words>` from a directory, and how it ended. Test support. The
--- sandbox tool tests pass descriptors and need 60 s: they have
--- [`build.sandbox_tool_fixture`].

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

local record tool_fixture
  --- How a run of the program ended and what it printed.
  record Ran
    code: integer
    out: string
    err: string
  end
end

--- Runs `cosmic <words>` in `dir`, feeding it `input` when given, and
--- returns how it ended. A child a signal ended has no code: -1 is none a
--- test expects.
--- @param dir the directory it starts in
--- @param words its command line after the program
--- @param input what it reads on its standard input
function tool_fixture.cosmic(dir: string, words: {string}, input?: string): tool_fixture.Ran
  local started = Test.cosmic(words, {
    cwd = dir, stdout = "capture", stderr = "capture", input = input,
    timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code or -1, out = result.stdout or "", err = result.stderr or "" }
end

--- The modules that the processes which wrote their profiles into `dir` (`COSMIC_PROFILE`) loaded from the store,
--- as a set: each `[require:<module>]` span of their profiles (core/profile.h), read here by its pattern alone, so a
--- test that asks what a process loads loads no reader of its own. A run that wrote none gives an empty set.
--- @param dir the profile directory the processes were given
function tool_fixture.loaded(dir: string): {string: boolean}
  local out: mut {string: boolean} = {}
  local names, _ = Fs.list(dir)
  for _, name in ipairs(names or {}) do
    local text, _ = Fs.read(dir .. "/" .. name)
    for module in (text or ""):gmatch("%[require:([^%]]+)%] %d") do out[module] = true end
  end
  return out
end

return tool_fixture
