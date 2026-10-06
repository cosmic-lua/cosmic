--- Whether the running process may make a unix socket, for the tests of
--- one: a worker started under the policy path makes one only where
--- Landlock ABI 9 tells a socket it was granted from another, or its root
--- shows no directory of the host's. Below ABI 9 every process it starts
--- inherits its filter, so none can make one either, whatever root it is
--- started in. A worker whose module declares nothing that binds a host
--- directory has such a root ([`build.test_sandbox`]'s `own_scratch`: its
--- scratch directory is a directory of the sandbox's own tmpfs, the tree
--- and the store files), and, with a `network` declared, a network
--- namespace of its own; a module that does not has its tests of a socket
--- file skipped there, naming the directories its root binds.

local type _net = require("cosmic.net")
local Fs = require("cosmic.fs")
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
  --- Whether the failure was a refusal (EPERM, the filter's errno), not any other.
  refused: boolean
  --- What the failed listen said, "" where it was made.
  why: string
end

--- Tries a unix listener at a socket file of `dir`, closed again.
local function listens(dir: string): Probe
  local listener, why, errno = raw_table().listen({ kind = "unix", path = dir .. "/unix-probe.sock" }, 1)
  if listener == nil then
    return { made = false, refused = errno == sys.EPERM, why = tostring(why) }
  end
  local _, _ = listener:close()
  return { made = true, refused = false, why = "" }
end

--- Whether the process is not refused a unix socket in `dir` (a listener
--- made there, or failed for another reason): for a case that adds a socket
--- file to what it checks where it may, and skips nothing.
--- @param dir a directory the process may make a socket file in
--- @return whether a socket file may be made
function unix_socket.available(dir: string): boolean
  return not listens(dir).refused
end

--- The host directories the running process's root binds, by mount point,
--- from its mount table: what keeps a worker from a unix socket below
--- Landlock ABI 9. The root, the sandbox's own /proc and its own /tmp are
--- not host directories.
local function bound_directories(): {string}
  local table_text, _ = Fs.read("/proc/self/mountinfo")
  local found: {string} = {}
  for line in (table_text or ""):gmatch("[^\n]+") do
    -- The fifth field is the mount point.
    local point = line:match("^%S+ %S+ %S+ %S+ (%S+)")
    local fstype = line:match(" %- (%S+)")
    if point ~= nil and point ~= "/" and point ~= "/tmp" and point ~= "/proc" and
        fstype ~= "proc" then
      local there, _ = sys.stat(point)
      if there ~= nil and there.kind == "dir" then found[#found + 1] = point end
    end
  end
  table.sort(found)
  return found
end

--- Whether a TCP listener on the loopback is refused, as a worker's filter
--- refuses it where its module declares no `network`.
local function listens_inet(): Probe
  local listener, why, errno = raw_table().listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 1)
  if listener == nil then
    return { made = false, refused = errno == sys.EPERM, why = tostring(why) }
  end
  local _, _ = listener:close()
  return { made = true, refused = false, why = "" }
end

--- Why the process cannot make a unix socket in `dir`, or nil where it
--- can. It cannot only where the listen is refused (EPERM, the filter's
--- errno), as the seccomp filter of a policy without a `u` grant refuses
--- `socket`: any other failure is nil, for the test to fail on. The reason
--- names the directories the worker's root binds, which its module's
--- [`Test.policy`] put there: the profile "system", the program, a directory
--- among its grants, a host cache or a private `noexec` scratch.
--- @param dir a directory the process may make a socket file in
--- @return the reason, or nil
function unix_socket.refusal(dir: string): string
  local tried = listens(dir)
  if not tried.refused then return nil end
  local reasons: {string} = {}
  local inet = listens_inet()
  if inet.refused then
    reasons[#reasons + 1] = "its module declares no `network`, so it has no network namespace of " ..
      "its own, which a unix socket needs to be held"
  end
  local directories = bound_directories()
  if #directories > 0 then
    reasons[#reasons + 1] = "its root binds the host directories " .. table.concat(directories, ", ") ..
      ", which only Landlock ABI 9 can hold a unix socket beside (a `system`, `tool`, host cache, " ..
      "`noexec` or directory `reads`/`host` declaration puts one there)"
  end
  if #reasons == 0 then reasons[1] = "its root is not one a unix socket is held in" end
  return "the worker cannot make a unix socket (" .. tried.why .. "): " .. table.concat(reasons, "; ")
end

--- Ends the running test as skipped ([`Test.skip`]) where the process
--- cannot make a unix socket in `dir` ([`unix_socket.refusal`]); false,
--- having said nothing, where it can. Outside a runner [`Test.skip`]
--- does not end the test, so this answers true there and the caller
--- returns.
--- @param dir a directory the process may make a socket file in
--- @return whether the test is skipped
function unix_socket.skipped(dir: string): boolean
  local why = unix_socket.refusal(dir)
  if why == nil then return false end
  Test.skip(why)
  return true
end

return unix_socket
