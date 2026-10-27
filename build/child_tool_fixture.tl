--- What the tests of cosmic.child that start this program again share
--- (cosmic/child_tool_test.tl and cosmic/child_sandbox_tool_test.tl): the
--- chunks a child runs.

local record child_tool_fixture
  --- A prefix for a chunk that starts a descendant: `again(chunk, opts)`
  --- starts this program once more, as `lua` does, running `chunk`.
  --- A chunk that leaves one running ends by [`sys.exit`], past the
  --- collector, whose end of the handle would end it, as a shell's `&`
  --- leaves it.
  AGAIN: string
end

child_tool_fixture.AGAIN = [[
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

--- A chunk's statement that sleeps `ms` milliseconds.
--- @param ms how long
--- @return the statement
function child_tool_fixture.sleeping(ms: integer): string
  return 'require("cosmic.clock").sleep_ns(require("cosmic.clock").ms(' .. tostring(ms) .. ')) '
end

return child_tool_fixture
