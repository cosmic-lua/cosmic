--- `children` on macOS, where libproc lists them (core/syscalls.c): apart
--- from core/syscalls_proc_children_test.tl, whose module requires Linux's
--- /proc list and so runs nowhere else.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local stand_in = require("build.stand_in")
local process = require("cosmic.internal.process")

local function probe_in(tmp: string): string
  return (assert(stand_in.build(tmp .. "/probe")))
end

local function darwin(): boolean
  return assert(sys.uname()).sysname == "Darwin"
end

--- A child still running is listed, and gone from the list once reaped.
local function test_children_lists_a_running_child_until_it_is_reaped(tmp: string)
  if not darwin() then
    Test.skip("Linux's list is checked in core/syscalls_proc_children_test.tl")
  end
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

--- A child that has ended is listed until it is reaped: the list is of
--- what a wait is still owed for.
local function test_children_lists_an_ended_child_until_it_is_reaped(tmp: string)
  if not darwin() then
    Test.skip("Linux's list is checked in core/syscalls_proc_children_test.tl")
  end
  local probe = probe_in(tmp)
  local ends = assert(process.pipe())
  local pid = assert(process.spawn(probe, { probe, "cat" }, nil, tmp, ends.reader, nil, nil, false))
  sys.close(ends.reader)
  local watch = assert(process.exit_watch(pid))
  sys.close(ends.writer)
  local ready = assert(sys.poll({ watch }, { sys.POLLIN }, 10000))
  local ended, trouble = process.children()
  sys.close(watch)
  assert(assert(process.waitpid(pid, false)).code == 0)
  assert(ready[1] ~= 0, "the child did not end")
  assert(ended ~= nil, trouble)
  local listed = false
  for _, child in ipairs(ended) do
    if child == pid then listed = true end
  end
  assert(listed, "the ended child " .. tostring(pid) .. " is not listed before it is reaped")
end
