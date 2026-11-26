--- `fork` of the raw process table (core/process.h) on macOS: a copy holds
--- no kqueue of its parent's, and a scoped fork is refused. The module
--- requires macOS; a scoped fork on Linux is core/fork_scoped_test.tl's.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local process = require("cosmic.internal.process")
local status_of = require("build.fork_fixture").status_of

Test.policy{ requires = { "os:darwin" } }

--- On macOS a kqueue is not the child's: the descriptor that watches a child's exit is closed in a copy.
local function test_a_kqueue_is_closed_in_the_copy_on_macos()
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
  local pid, why, number = process.fork(true)
  if pid == 0 then sys.exit(0) end
  if pid ~= nil then local _ = status_of(pid) end
  assert(pid == nil and number == sys.ENOSYS, why)
end
