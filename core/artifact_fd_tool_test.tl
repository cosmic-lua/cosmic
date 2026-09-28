--- A test that declares `tool` is given the program at its own name,
--- and opens it there: only a name that reaches it through one of its
--- descriptors is refused (core/syscalls_fs.c's
--- `artifact_through_descriptor`, whose walk refusing descriptor links
--- finds it by that name). Its own module, since a `tool` test runs
--- again on every edit to the tree.

local sys = require("cosmic.sys")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

Test.needs{ tool = true }

local function test_a_tool_opens_the_program_by_its_own_name()
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil then return end
  local program = assert(Proc.executable())
  local fd, trouble = sys.open(program, sys.O_RDONLY)
  assert(fd ~= nil, "a tool could not open " .. program .. ": " .. tostring(trouble))
  assert(sys.read(fd, 2) == "#!")
  assert(sys.close(fd))
end
