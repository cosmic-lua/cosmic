--- A restriction refuses a named descriptor that is not open before
--- inspecting /proc or applying any limit or filter.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")
local type _ = require("cosmic.child")

local function test_unix_socket_creation_reports_the_hosts_permission()
  local fd, why, errno = require("cosmic.internal.process").unix_socket()
  if fd ~= nil then
    local flags = assert(sys.fd_flags(fd))
    assert(sys.close(fd))
    assert(flags & sys.FD_CLOEXEC ~= 0)
  else
    assert(type(why) == "string" and why ~= "")
    assert(errno == sys.EPERM or errno == sys.EACCES or errno == sys.EAFNOSUPPORT or
        errno == sys.EPROTONOSUPPORT or errno == sys.ENOSYS, why)
  end
end

local function test_a_named_descriptor_that_is_not_open_refuses_before_inspection()
  local fd <const> = 2147483647
  assert(sys.fd_flags(fd) == nil)
  -- On macOS the restriction is a profile, read before the descriptors.
  local restriction: raw_process.Restriction = { promises = {}, grants = {}, rlimits = {},
    seatbelt = if assert(sys.uname()).sysname == "Darwin" then { profile = "(version 1)", parameters = {} } else nil end }
  local ok, why, errno = require("cosmic.internal.process").restrict_self(restriction, { fd })
  assert(not ok)
  if errno == sys.ENOSYS then
    assert(why == "Function not implemented", why)
  else
    assert(errno == sys.EBADF and why == "descriptor " .. tostring(fd) .. ", which fds names, is not open", why)
  end
end

local function test_an_execute_restriction_refuses_a_path_that_is_not_a_string()
  local apply = require("cosmic.internal.process").landlock_restrict_execute
  local ok, why = pcall(apply, { false } as {string}) -- cast: a deliberately degenerate argument -- checked: cast_refused
  assert(not ok and tostring(why):find("path must be a string", 1, true) ~= nil, tostring(why))
end

--- No user namespace is needed for a filter on a child that does not
--- unveil: the filter is installed before exec reports the absent file.
local function test_a_promises_filter_is_applied_before_an_absent_program_is_refused(tmp: string)
  local path = tmp .. "/absent"
  local pid, why, errno = require("cosmic.internal.process").spawn(path, { path }, nil, nil, nil, nil, nil,
    false, nil, { promises = {} })
  assert(pid == nil)
  local names = assert(sys.uname())
  if names.sysname == "Linux" then
    if errno == sys.EPERM or errno == sys.ENOSYS then
      Test.skip("the host refuses a child's seccomp filter: " .. why)
    end
    assert(errno == sys.ENOENT and why == "No such file or directory", why)
  else
    assert(errno == sys.ENOSYS and why == "Function not implemented", why)
  end
end

--- A restriction refused after it opened its /proc handles leaves them open;
--- a fork copies them, and a restriction in the copy lets them go: it closes a
--- copy that still names its parent's entry, and leaves open a file the
--- program put in the number of one -- a file it names in fds.
local function test_a_forked_restriction_leaves_open_a_file_put_in_its_parents_handles()
  local names = assert(sys.uname())
  if names.sysname ~= "Linux" then Test.skip("the /proc handles are Linux's") end
  local process = require("cosmic.internal.process")
  local restriction: raw_process.Restriction = { promises = {}, grants = {}, rlimits = {} }
  -- An end not named in fds, so each restriction here is refused, after it inspects /proc.
  local held = assert(process.pipe())
  local refused, why = process.restrict_self(restriction, {})
  assert(not refused, why)
  local parent = sys.getpid()
  local pid, fork_why = process.fork(false)
  if pid == 0 then
    --- The descriptors that name an entry of the parent's /proc, in order.
    local function parents(): {integer}
      local found: mut {integer} = {}
      for name in pairs(sys.readdir("/proc/self/fd") or {}) do
        local target = sys.readlink("/proc/self/fd/" .. name)
        local fd = math.tointeger(tonumber(name))
        if fd ~= nil and target ~= nil and target:find("^/proc/" .. tostring(parent) .. "/") ~= nil then
          found[#found + 1] = fd
        end
      end
      table.sort(found)
      return found
    end
    local handles = parents()
    local replaced = handles[1] or -1
    if replaced >= 0 then assert(sys.dup2(held.reader, replaced)) end
    local _, _ = process.restrict_self(restriction, { replaced })
    -- Still the pipe: a handle closed here would be opened again in its number.
    local now = sys.readlink("/proc/self/fd/" .. tostring(replaced))
    local kept = now ~= nil and now:find("^pipe:") ~= nil
    local left = #parents()
    local status = 10 + #handles * 4 + (if kept then 0 else 1 end) + (if left == 0 then 0 else 2 end)
    sys.exit(if #handles == 3 and kept and left == 0 then 0 else status end)
  end
  assert(pid ~= nil, fork_why)
  local status, wait_why = process.waitpid(pid, false)
  assert(status ~= nil, wait_why)
  assert(sys.close(held.reader) and sys.close(held.writer))
  assert(status.code == 0, "child status " .. tostring(status.code) ..
      " (10 + 4 x the parent's handles found, + 1 if the replaced one is not the pipe, + 2 if any is left)")
end
