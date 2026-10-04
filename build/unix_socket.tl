--- Whether the running process may make a unix socket, for the tests of
--- one: a worker started under the policy path makes one only with a `u`
--- grant, which a kernel below Landlock ABI 9 cannot give beside another
--- directory, so a test of a socket file in its scratch directory is
--- skipped there, naming why.

local type _net = require("cosmic.net")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local type raw_socket = require("cosmic.internal.socket")

local type Searcher = function(string): any, any

local record unix_socket
end

--- The raw socket table the store's searcher hands [`cosmic.net`]'s
--- loader, whose `listen` fails with an errno, which [`Net.listen`]'s
--- message has no shape for.
local function raw_table(): raw_socket
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.net")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_socket -- cast: the table core/socket.h declares
    end
  end
  error("cosmic.net is handed no raw table")
end

--- What a try at a unix listener came to.
local record Probe
  --- Whether the listener was made (and closed again).
  made: boolean
  --- Whether the failure was a refusal (EPERM or EACCES), not any other.
  refused: boolean
  --- What the failed listen said, "" where it was made.
  why: string
end

--- Tries a unix listener at a socket file of `dir`, closed again.
local function listens(dir: string): Probe
  local listener, why, errno = raw_table().listen({ kind = "unix", path = dir .. "/unix-probe.sock" }, 1)
  if listener == nil then
    return { made = false, refused = errno == sys.EPERM or errno == sys.EACCES, why = tostring(why) }
  end
  local _, _ = listener:close()
  return { made = true, refused = false, why = "" }
end

--- Says the running test is skipped ([`Test.skip`]) where the process
--- cannot make a unix socket in `dir`, and answers true then, for the test
--- to return; false, having said nothing, where it can. It is skipped only
--- where the listen is refused (EPERM or EACCES), as the seccomp filter of
--- a policy without a `u` grant refuses `socket`: any other failure falls
--- through, for the test to fail on.
--- @param dir a directory the process may make a socket file in
--- @return whether the test is skipped
-- TODO: delete this skip, and give each such test the `u` grant it
-- needs, once the kernels the suite runs on give Landlock ABI 9 (the
-- TODOs at core/syscalls.c's `u` and build/test_policy.tl's
-- `base_promises`): below it a worker that is granted a unix socket may
-- be granted no other directory, so a socket file in its scratch
-- directory cannot be reached.
function unix_socket.skipped(dir: string): boolean
  local tried = listens(dir)
  if not tried.refused then return false end
  Test.skip("the worker cannot make a unix socket (" .. tried.why .. "): its policy has no `u` grant, " ..
      "which needs Landlock ABI 9 to sit beside another directory")
  return true
end

return unix_socket
