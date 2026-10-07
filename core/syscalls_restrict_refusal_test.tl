--- A restriction refuses a named descriptor that is not open before
--- inspecting /proc or applying any limit or filter.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")
local type _ = require("cosmic.child")

local type Searcher = function(string): any, any

local function raw_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: the table core/process.h declares
    end
  end
  error("cosmic.child is handed no raw table")
end

local function test_unix_socket_creation_reports_the_hosts_permission()
  local fd, why, errno = raw_table().unix_socket()
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
  local restriction: raw_process.Restriction = { promises = {}, grants = {}, rlimits = {} }
  -- On macOS the restriction is a profile, read before the descriptors.
  if assert(sys.uname()).sysname == "Darwin" then
    restriction.seatbelt = { profile = "(version 1)", parameters = {} }
  end
  local ok, why, errno = raw_table().restrict_self(restriction, { fd })
  assert(not ok)
  if errno == sys.ENOSYS then
    assert(why == "Function not implemented", why)
  else
    assert(errno == sys.EBADF and why == "descriptor " .. fd .. ", which fds names, is not open", why)
  end
end

local function test_an_execute_restriction_refuses_a_path_that_is_not_a_string()
  local apply = raw_table().landlock_restrict_execute
  local ok, why = pcall(apply, { false } as {string}) -- cast: a deliberately degenerate argument
  assert(not ok and tostring(why):find("path must be a string", 1, true), tostring(why))
end

--- No user namespace is needed for a filter on a child that does not
--- unveil: the filter is installed before exec reports the absent file.
local function test_a_promises_filter_is_applied_before_an_absent_program_is_refused(tmp: string)
  local path = tmp .. "/absent"
  local pid, why, errno = raw_table().spawn(path, { path }, nil, nil, nil, nil, nil,
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

--- A regular file is an open descriptor, but cannot restrict a child.
--- The child must refuse it before attempting the absent executable.
local function test_a_regular_file_descriptor_is_not_a_ruleset(tmp: string)
  local fd = assert(sys.open(tmp .. "/regular", sys.O_CREAT | sys.O_RDWR | sys.O_EXCL, 420))
  local path = tmp .. "/absent"
  local pid, why, errno = raw_table().spawn(path, { path }, nil, nil, nil, nil, nil,
    false, nil, { ruleset = fd })
  assert(sys.close(fd))
  assert(pid == nil)
  assert(sys.errno_name(errno) == "EBADFD" or errno == sys.ENOSYS or errno == sys.EPERM, why)
  assert(why == sys.errno_message(errno), why)
end
