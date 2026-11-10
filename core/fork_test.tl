--- `fork` of the raw process table (core/process.h): the copy runs on from
--- the call, and a scoped one is held to signalling itself.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local process = require("cosmic.internal.process")

--- Whether this host forks at all: Linux.
local function linux(): boolean
  return assert(sys.uname()).sysname == "Linux"
end

--- Reaps `pid` and answers its exit status, -1 for one a signal ended.
local function status_of(pid: integer): integer
  local status, why = process.waitpid(pid, false)
  assert(status ~= nil, why)
  assert(status.pid == pid, "the wait reaped another process")
  return status.code
end

--- The child is a copy that runs on from the call: it sees the parent's
--- values, answers 0, has a pid of its own, and what it writes to a pipe made
--- before the fork the parent reads.
local function test_a_fork_runs_on_in_a_copy()
  if not linux() then Test.skip("fork is Linux's") end
  local pipe = assert(process.pipe())
  local before = sys.getpid()
  local carried = "made before the fork"
  local pid, why = process.fork(false)
  if pid == 0 then
    local mine = sys.getpid()
    local said = if mine ~= before then carried else "the child has its parent's pid" end
    local _, _ = sys.write(pipe.writer, said)
    sys.exit(7)
  end
  assert(pid ~= nil, why)
  assert(pid > 0 and pid ~= before, "the parent is answered the child's pid")
  assert(sys.close(pipe.writer))
  assert(status_of(pid) == 7, "the child's own exit status is the one reaped")
  local read = assert(sys.read(pipe.reader, 64))
  assert(sys.close(pipe.reader))
  assert(read == carried, read)
  assert(sys.getpid() == before, "the parent runs on as itself")
end

--- A scoped child can signal itself and not its parent; an unscoped one can
--- signal its parent. Signal 0 asks only whether the signal may be sent.
local function test_a_scoped_fork_cannot_signal_its_parent()
  if not linux() then Test.skip("fork is Linux's") end
  local abi, abi_why = process.landlock_abi()
  if abi == nil then
    Test.skip("no Landlock here: " .. abi_why)
    return
  end
  if abi < 6 then
    local refused, _, number = process.fork(true)
    if refused == 0 then sys.exit(0) end
    assert(refused == nil and number == sys.EOPNOTSUPP, "a scoped fork is refused below Landlock ABI 6")
    Test.skip("Landlock ABI " .. tostring(abi) .. " scopes no signal")
  end
  local parent = sys.getpid()
  -- Each child exits 0 where what it may signal is as its fork says, else with the step that was not.
  local function probe(scoped: boolean): integer
    local pid, why = process.fork(scoped)
    if pid == 0 then
      local own, _ = sys.kill(sys.getpid(), 0)
      if not own then sys.exit(2) end
      local reached, _, number = sys.kill(parent, 0)
      if scoped then
        sys.exit(if not reached and number == sys.EPERM then 0 else 3 end)
      end
      sys.exit(if reached then 0 else 4 end)
    end
    assert(pid ~= nil, why)
    return status_of(pid)
  end
  local unscoped = probe(false)
  if unscoped == 4 then
    Test.skip("this worker's filter holds a signal to its own pid, so no child signals its parent")
  end
  assert(unscoped == 0, "an unscoped child's status: " .. tostring(unscoped))
  local scoped = probe(true)
  assert(scoped == 0, "a scoped child's status: " .. tostring(scoped))
end

-- TODO: test that a process with another thread is refused (EBUSY), once a binding the core gives a test starts a
-- thread: none does today, so no test can have two.

--- Off Linux there is no fork.
local function test_fork_is_not_implemented_off_linux()
  if linux() then Test.skip("Linux has fork") end
  local pid, why, number = process.fork(false)
  assert(pid == nil and number == sys.ENOSYS, why)
end
