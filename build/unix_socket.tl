--- Whether the running process may make a unix socket, for the tests of
--- one: a worker started under the policy path makes one only with a `u`
--- grant, which a kernel below Landlock ABI 9 cannot give beside another
--- directory, so a test of a socket file in its scratch directory is
--- skipped there, naming why.

local Net = require("cosmic.net")
local Test = require("cosmic.test")
local Fs = require("cosmic.fs")

local record unix_socket
end

--- Whether a seccomp filter holds this process, as /proc/self/status says
--- ("Seccomp: 2"): the one that refuses `socket` to a policy without a `u`
--- grant. The listen's failure carries no errno to tell a refusal by, and
--- its message is no shape to read.
local function filtered(): boolean
  local status, _ = Fs.read("/proc/self/status")
  return status ~= nil and status:match("\nSeccomp:%s*(%d+)") == "2"
end

--- Says the running test is skipped ([`Test.skip`]) where the process
--- cannot make a unix socket in `dir`, and answers true then, for the test
--- to return; false, having said nothing, where it can. The probe is a
--- listener at a socket file of `dir`, closed again; it is skipped only
--- where it fails and a seccomp filter holds the process, as that of a
--- policy without a `u` grant refuses `socket`: a failure with no filter
--- falls through, for the test to fail on.
--- @param dir a directory the process may make a socket file in
--- @return whether the test is skipped
-- TODO: delete this skip, and give each such test the `u` grant it
-- needs, once the kernels the suite runs on give Landlock ABI 9 (the
-- TODOs at core/syscalls.c's `u` and build/test_policy.tl's
-- `base_promises`): below it a worker that is granted a unix socket may
-- be granted no other directory, so a socket file in its scratch
-- directory cannot be reached.
function unix_socket.skipped(dir: string): boolean
  local listener, why = Net.listen(Net.unix(dir .. "/unix-probe.sock"))
  if listener ~= nil then
    local _, _ = listener:close()
    return false
  end
  -- Only a refusal is the sandbox's; any other failure is the test's to meet.
  if not filtered() then return false end
  Test.skip("the worker cannot make a unix socket (" .. why .. "): its policy has no `u` " ..
      "grant, which needs Landlock ABI 9 to sit beside another directory")
  return true
end

return unix_socket
