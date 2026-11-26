--- `fork` of the raw process table (core/process.h): the copy runs on from
--- the call, on Linux and macOS. A scoped fork, which is Linux's, is
--- core/fork_scoped_test.tl's; what a copy holds on macOS alone is
--- core/fork_darwin_test.tl's.

local sys = require("cosmic.sys")
local process = require("cosmic.internal.process")
local status_of = require("build.fork_fixture").status_of

--- The child is a copy that runs on from the call: it sees the parent's
--- values, gets 0 from the call, has a pid of its own, and what it writes
--- to a pipe made before the fork the parent reads.
local function test_a_fork_runs_on_in_a_copy()
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

-- TODO: test that a process with another thread is refused (EBUSY), once a binding the core gives a test starts a
-- thread: none does today, so no test can have two.

--- A fork is refused while a signal guard is open, and made once it is closed.
local function test_a_fork_is_refused_while_a_signal_guard_is_open()
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
