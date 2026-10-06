--- The raw calls a sandbox's own setup makes (cosmic.internal.testing's
--- mount, umount2, unshare, setns and chroot), which every core carries:
--- each in its shape, true, or false, the message and the errno, never a
--- raise. What they do inside a sandbox is
--- cosmic/child_policy_nest_calls_test.tl's.

local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")

--- Made so that nothing changes, run as anyone, sandboxed or not: an
--- unshare of nothing, and the rest on what is not there to act on.
local function test_the_sandbox_calls_answer_true_or_an_errno(tmp: string)
  local function shaped(name: string, ok: boolean, why: string, errno: integer)
    assert(ok == true or (ok == false and type(why) == "string" and why ~= "" and
      math.type(errno) == "integer" and errno > 0), name .. ": " .. tostring(why))
  end
  local missing = tmp .. "/missing"
  local ok, why, errno = testing.unshare(0)
  assert(ok or errno == sys.EPERM or errno == sys.ENOSYS, "unshare(0): " .. tostring(why))
  shaped("unshare", ok, why, errno)
  ok, why, errno = testing.mount(nil, missing, nil, 0)
  assert(not ok, "a mount of nothing on nothing")
  shaped("mount", ok, why, errno)
  ok, why, errno = testing.umount2(missing, 0)
  assert(not ok, "an unmount of nothing")
  shaped("umount2", ok, why, errno)
  ok, why, errno = testing.setns(-1, 0)
  assert(not ok, "setns on no descriptor")
  shaped("setns", ok, why, errno)
  ok, why, errno = testing.chroot(missing)
  assert(not ok, "a chroot into nothing")
  shaped("chroot", ok, why, errno)
  assert(not pcall(testing.mount, nil, missing, nil, -1), "negative mount flags raise")
end
