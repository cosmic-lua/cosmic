--- Listing live and reaped children where the kernel exposes its list.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local stand_in = require("build.stand_in")
local process = require("cosmic.internal.process")

local function probe_in(tmp: string): string
  return (assert(stand_in.build(tmp .. "/probe")))
end

Test.policy{ profiles = { "proc" }, requires = { "path:/proc/thread-self/children" } }

--- `children` lists the children of the thread that starts them, a
--- child still running among them and gone once reaped; off Linux there
--- is no such list, ENOSYS.
local function test_children_lists_a_running_child_until_it_is_reaped(tmp: string)
  local probe = probe_in(tmp)
  local ends = assert(process.pipe())
  local pid = assert(process.spawn(probe, { probe, "cat" }, nil, tmp, ends.reader, nil, nil, false))
  sys.close(ends.reader)
  local running, trouble = process.children()
  sys.close(ends.writer)
  assert(assert(process.waitpid(pid, false)).code == 0)
  assert(running ~= nil, trouble)
  local listed = false
  for _, child in ipairs(running) do
    assert(math.type(child) == "integer" and child > 0)
    if child == pid then listed = true end
  end
  assert(listed, "the running child " .. tostring(pid) .. " is not listed")
  for _, child in ipairs((assert(process.children()))) do
    assert(child ~= pid, "the reaped child " .. tostring(pid) .. " is still listed")
  end
end
