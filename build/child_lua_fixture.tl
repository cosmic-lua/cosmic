--- What cosmic/child_lua_test.tl and cosmic/child_lua_strays_test.tl share:
--- a child that is this program again, past its launcher, running a Lua
--- chunk, and the chunk prefixes that build one. Test support.

local Child = require("cosmic.child")
local this_program = require("build.this_program")

local record child_lua_fixture
  --- A chunk's prefix: cosmic.fs as `Fs`.
  FS: string
  --- A prefix for a chunk that starts a descendant: `again(chunk, opts)`
  --- starts this program once more, as `lua` does, running `chunk`.
  --- A chunk that leaves one running ends by [`sys.exit`], past the
  --- collector, whose end of the handle would end it, as a shell's `&`
  --- leaves it.
  AGAIN: string
end

child_lua_fixture.FS = 'local Fs = require("cosmic.fs") '

child_lua_fixture.AGAIN = [[
local Child = require("cosmic.child")
local this_program = require("build.this_program")
local function again(chunk, opts)
  local started = this_program.program({ "-e", chunk }, opts)
  return assert(Child.start(started.argv, started.options))
end
]]

--- This program again, past its launcher ([`this_program.program`]),
--- running the Lua chunk `chunk` with `args` as its `...`: the child
--- each test starts, where a shell would need the system's. Its argv and
--- options are for [`Child.run`] or [`Child.start`].
function child_lua_fixture.lua(chunk: string, args?: {string}, opts?: Child.Options): this_program.Program
  local words: {string} = { "-e", chunk }
  for _, word in ipairs(args or {}) do words[#words + 1] = word end
  return this_program.program(words, opts)
end

--- A chunk's statement that sleeps `ms` milliseconds.
function child_lua_fixture.sleeping(ms: integer): string
  return 'require("cosmic.clock").sleep_ns(require("cosmic.clock").ms(' .. tostring(ms) .. ')) '
end

return child_lua_fixture
