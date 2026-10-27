--- What cosmic/child_lua_test.tl and cosmic/child_lua_strays_test.tl share:
--- a child that is this program again, past its launcher, running a Lua
--- chunk, and the chunk prefixes that build one. Test support.

local Child = require("cosmic.child")
local this_program = require("build.this_program")

local record child_lua_fixture
  --- A chunk's prefix: cosmic.fs as `Fs`.
  FS: string
  --- A prefix for a chunk that starts a descendant: `again(chunk, opts)`
  --- starts this program once more, as `lua` does, running `chunk`, with
  --- the environment of the chunk's process and `opts.process_group`, the
  --- one option it takes.
  --- A chunk that leaves one running ends by [`sys.exit`], past the
  --- collector, whose end of the handle would end it, as a shell's `&`
  --- leaves it.
  AGAIN: string
end

child_lua_fixture.FS = 'local Fs = require("cosmic.fs") '

child_lua_fixture.AGAIN = [[
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local function again(chunk: string, opts?: Child.Options): Child.Handle
  local relaunch = assert(Proc.relaunch())
  local argv: mut {string} = {}
  for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = chunk
  local env: mut {string:string} = Env.all()
  for name, value in pairs(relaunch.env) do env[name] = value end
  local group: boolean? = nil
  if opts ~= nil then group = opts.process_group end
  local handle = assert(Child.start(argv, { env = env, fds = relaunch.fds, process_group = group }))
  return handle
end
]]

--- This program again, past its launcher ([`this_program.program`]),
--- running the Teal chunk `chunk` with `args` as its `...`: the child
--- each test starts, where a shell would need the system's. Its argv and
--- options are for [`Child.run`] or [`Child.start`].
function child_lua_fixture.lua(chunk: string, args?: {string}, opts?: Child.Options): this_program.Program
  local words: mut {string} = { "-e", chunk }
  for _, word in ipairs(args or {}) do words[#words + 1] = word end
  return this_program.program(words, opts)
end

--- A chunk's statement that sleeps `ms` milliseconds.
function child_lua_fixture.sleeping(ms: integer): string
  return 'require("cosmic.clock").sleep_ns(require("cosmic.clock").ms(' .. tostring(ms) .. ')) '
end

return child_lua_fixture
