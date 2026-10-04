--- Whether the running process may make a unix socket, for the tests of
--- one: a worker started under the policy path makes one only with a `u`
--- grant, which a kernel below Landlock ABI 9 cannot give beside another
--- directory, so a test of a socket file in its scratch directory is
--- skipped there, naming why.

local Net = require("cosmic.net")
local Test = require("cosmic.test")

local record unix_socket
end

--- Says the running test is skipped ([`Test.skip`]) where the process
--- cannot make a unix socket in `dir`, and answers true then, for the test
--- to return; false, having said nothing, where it can. The probe is a
--- listener at a socket file of `dir`, closed again; where it fails,
--- nothing but the worker's own sandbox can have refused it, a seccomp
--- filter that holds `socket` EPERM where its policy has no `u` grant.
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
  Test.skip("the worker cannot make a unix socket (" .. why .. "): its policy has no `u` " ..
      "grant, which needs Landlock ABI 9 to sit beside another directory")
  return true
end

return unix_socket
