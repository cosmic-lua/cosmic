--- `fork` of the raw process table (core/process.h): the copy runs on from
--- the call, on Linux and macOS, and a scoped one, which is Linux's, is held
--- to signalling itself.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local process = require("cosmic.internal.process")

local system <const> = assert(sys.uname()).sysname

--- Whether this host scopes a fork: Linux.
local function linux(): boolean
  return system == "Linux"
end

--- Whether this host forks at all: Linux and macOS.
local function forks(): boolean
  return system == "Linux" or system == "Darwin"
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
  if not forks() then Test.skip("no fork here") end
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
  if not linux() then Test.skip("a scoped fork is Linux's") end
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

--- A scoped child moves a file from one directory to another, as its parent may: the ruleset that scopes its
--- signals refuses no move.
local function test_a_scoped_fork_moves_a_file_between_directories(tmp: string)
  if not linux() then Test.skip("a scoped fork is Linux's") end
  local abi, abi_why = process.landlock_abi()
  if abi == nil then
    Test.skip("no Landlock here: " .. abi_why)
    return
  end
  if abi < 6 then Test.skip("Landlock ABI " .. tostring(abi) .. " scopes no signal") end
  assert(sys.mkdir(tmp .. "/from", 0x1c0))
  assert(sys.mkdir(tmp .. "/to", 0x1c0))
  local made = assert(sys.open(tmp .. "/from/file", sys.O_WRONLY | sys.O_CREAT, 0x180))
  assert(sys.close(made))
  local pid, why = process.fork(true)
  if pid == 0 then
    local moved, _, number = sys.rename(tmp .. "/from/file", tmp .. "/to/file")
    sys.exit(if moved then 0 elseif number == sys.EXDEV then 3 else 4 end)
  end
  assert(pid ~= nil, why)
  local status = status_of(pid)
  assert(status == 0, "a scoped child's move, 3 for one refused as between devices: " .. tostring(status))
  assert(sys.lstat(tmp .. "/to/file") ~= nil, "the file is where the child moved it")
end

-- TODO: test that a process with another thread is refused (EBUSY), once a binding the core gives a test starts a
-- thread: none does today, so no test can have two.

--- A fork is refused while a signal guard is open, and made once it is closed.
local function test_a_fork_is_refused_while_a_signal_guard_is_open()
  if not forks() then Test.skip("no fork here") end
  local guard = assert(process.guard_child_signals())
  local pid, why, number = process.fork(false)
  if pid == 0 then sys.exit(0) end
  process.unguard_child_signals(guard)
  if pid ~= nil then local _ = status_of(pid) end
  assert(pid == nil, "a fork was made while a signal guard was open")
  assert(sys.errno_name(number) == "EBUSY", why)
  local after, after_why = process.fork(false)
  if after == 0 then sys.exit(9) end
  assert(after ~= nil, after_why)
  assert(status_of(after) == 9)
end

--- On macOS a kqueue is not the child's: the descriptor that watches a child's exit is closed in a copy.
local function test_a_kqueue_is_closed_in_the_copy_on_macos()
  if system ~= "Darwin" then Test.skip("a kqueue is macOS's") end
  local watched, watched_why = process.fork(false)
  if watched == 0 then
    local _, _ = sys.nanosleep(10 * 1000000000)
    sys.exit(0)
  end
  assert(watched ~= nil, watched_why)
  local watch = assert(process.exit_watch(watched))
  assert(sys.fstat(watch) ~= nil, "the parent holds the watch")
  local pid, why = process.fork(false)
  if pid == 0 then
    local held, _, number = sys.fstat(watch)
    sys.exit(if held == nil and number == sys.EBADF then 0 else 3 end)
  end
  local status = if pid ~= nil then status_of(pid) else -2 end
  local _, _ = sys.kill(watched, sys.SIGKILL)
  local _ = status_of(watched)
  assert(sys.close(watch))
  assert(pid ~= nil, why)
  assert(status == 0, "the copy's look at the watch, 3 for one still open: " .. tostring(status))
end

--- A scoped fork is refused on macOS, which scopes no child's signals, and makes no child.
local function test_a_scoped_fork_is_refused_on_macos()
  if system ~= "Darwin" then Test.skip("Linux scopes a fork") end
  local pid, why, number = process.fork(true)
  if pid == 0 then sys.exit(0) end
  if pid ~= nil then local _ = status_of(pid) end
  assert(pid == nil and number == sys.ENOSYS, why)
end
