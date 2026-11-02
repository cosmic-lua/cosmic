--- A child's status, walked the way core/allocation_test.tl walks the
--- paths a C binding takes when an allocation fails: the one of its
--- walks that starts the program again, apart so the rest stand while
--- the tree moves. Only the checked core can refuse an allocation
--- (core/testing.h), and CI runs this suite on it; on any other the
--- walk returns at once.

local AllocationFixture = require("build.allocation_fixture")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local type raw_process = require("cosmic.internal.process")
local Test = require("cosmic.test")

--- The program itself, which the checked core starts again in
--- [`test_waitpid_never_loses_a_status_to_a_failed_allocation`] (the
--- spawn refusal names it, and never starts it).
Test.policy{ requires = { "checked" }, profiles = { "cosmic" } }

local process = require("cosmic.internal.process")

--- This program again, past its launcher, as build.this_program's
--- `program` starts it, handed the chunk `chunk`. A test's worker
--- always runs from a portable artifact.
local function spawn_again(chunk: string): integer
  local relaunch = assert(Proc.relaunch())
  local program = assert(relaunch.argv[1], "the relaunch names a program")
  local argv: mut {string} = { table.unpack(relaunch.argv) }
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = chunk
  return (assert(process.spawn(program, argv, relaunch.env, nil, nil, nil, nil, false,
    relaunch.fds)))
end

--- A child is reaped only once its answer can be made: a refusal before
--- it leaves the child to wait for again, never its status lost.
local function test_waitpid_never_loses_a_status_to_a_failed_allocation()
  -- A chunk that exits 7: a real status to reap.
  local pid = spawn_again("return 7")
  local received = { value = nil as raw_process.ChildStatus? } -- checked: cast_refused
  local reaped = { value = nil as raw_process.ChildStatus? } -- checked: cast_refused
  AllocationFixture.under_every_failure(function()
    if reaped.value == nil then received.value = process.waitpid(pid, false) end -- checked: map_field*2
  end, function()
    local value = received.value -- checked: map_field
    if value ~= nil then
      reaped.value = value -- checked: map_field
      received.value = nil -- checked: map_field
    end
  end)
  local reaped_value = reaped.value -- checked: map_field
  assert(reaped_value ~= nil, "the child's status was lost to a refused allocation")
  assert(reaped_value.pid == pid and reaped_value.code == 7 and reaped_value.signal == -1)
end

--- An exit watch owns its descriptor from the call that opens it: a
--- refusal anywhere, its failure's message among them, leaves none to
--- the process.
local function test_an_exit_watch_leaves_no_descriptor_whenever_an_allocation_fails(tmp: string)
  -- A child still running, as one a watch is opened for is.
  local pid = spawn_again('require("cosmic.clock").sleep_ns(60 * 1000000000)')
  local probe = tmp .. "/probe"
  local function next_descriptor(): integer
    local fd = assert(sys.open(probe, sys.O_CREAT | sys.O_RDWR, 420))
    sys.close(fd)
    return fd
  end
  local before = next_descriptor()
  local received = { value = nil as integer? } -- checked: cast_refused
  local opened = { value = 0 }
  AllocationFixture.under_every_failure(function()
    received.value = process.exit_watch(pid) -- checked: map_field
  end, function()
    local value = received.value -- checked: map_field
    if value ~= nil then
      sys.close(value)
      received.value = nil -- checked: map_field
      opened.value = opened.value + 1 -- checked: map_field*2
    end
  end)
  assert(opened.value >= 1, "the run with nothing refused opens a watch") -- checked: map_field
  assert(sys.kill(pid, sys.SIGKILL))
  assert(process.waitpid(pid, false))
  -- Reaped, the child has no watch to give, and its failure is made
  -- under every refusal too.
  AllocationFixture.under_every_failure(function()
    local none, _, errno = process.exit_watch(pid)
    assert(none == nil and errno == sys.ESRCH)
  end)
  assert(next_descriptor() == before, "a refused allocation left descriptor " .. tostring(before) .. " open")
end
