--- [`Child.start`]'s `policy` with the `nest` promise (cosmic/child.tl), where
--- what the kernel is asked to hold is held by Landlock: a start without
--- `nest` handed a directory, and a fake ([`cosmic.fake`]) that starts
--- a sandbox of its own, which Landlock holds inside the root of the first.
--- They need a host that lets a sandbox nest and gives Landlock
--- (`requires`): where the platform has neither they are not applicable,
--- and where this host gives no seccomp each skips itself (Test.skip). What
--- a root holds alone is cosmic/child_policy_nest_test.tl's.

local Child = require("cosmic.child")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local ChildPolicy = require("build.child_policy_fixture")

--- The temporary directory, which a start's root is built in, and `nests`,
--- since the sandboxes this test makes are roots a worker held by a
--- Landlock ruleset cannot build.
Test.policy{
  env = { "TMPDIR" },
  promises = { "nest" },
  requires = { "landlock", "nest" },
}

--- Without `nest` a directory is handed to a start (with it, the start is
--- refused: cosmic/child_policy_nest_test.tl), and Landlock holds what the
--- child reaches through it.
local function test_a_handed_directory_is_held_by_landlock_without_nest(tmp: string)
  local at = ChildPolicy.nest_placed(tmp)
  local dir = assert(sys.open(at.extra, sys.O_RDONLY))
  local policy: Sandbox.Policy = { isolate = { "file" }, grants = ChildPolicy.with(at.grants, { calls = "fork" }) }
  -- Started with no promise at all, the directory is taken.
  local plain, plain_why = Child.start({ at.probe, "print hi" },
    { timeout_ns = Child.FOREVER, policy = { isolate = { "file" }, grants = at.grants }, cwd = at.work, fds = { [3] = dir } })
  assert(plain ~= nil, plain_why)
  local _, _ = plain:close()
  local ran = ChildPolicy.under(at.probe, policy, at.work, "cat /proc/self/fd/3/e", { [3] = dir })
  sys.close(dir)
  assert(ran.code == 1 and ran.said:find("Permission denied", 1, true) ~= nil, tostring(ran.code) .. ": " .. ran.said)
end

--- Where a start of the program's own meets its host: the directory a root
--- is built in is in TMPDIR, which the sandbox grants.
local function nested(at: ChildPolicy.NestPlace): Sandbox.Policy
  return { isolate = { "file" }, set_env = { TMPDIR = at.scratch },
    grants = ChildPolicy.with(at.grants, { path = at.scratch, letters = "rwc" },
      { path = at.extra, letters = "r" }, { calls = "fork" }, { calls = "nest" }) }
end

local function test_a_nested_sandbox_is_confined_to_its_own_grants(tmp: string)
  local at = ChildPolicy.nest_placed(tmp)
  local policy = nested(at)
  -- The first sandbox reads the extra directory, the fake's own sandbox,
  -- granted the fake and the working directory, does not.
  local own = ChildPolicy.under(at.probe, policy, at.work, "cat " .. at.extra .. "/e")
  assert(own.code == 0 and own.said == "epsilon\n", tostring(own.code) .. ": " .. own.said)
  local ran = ChildPolicy.under(at.probe, policy, at.work, "run-isolated " .. at.probe .. " cat ro/a")
  assert(ran.code == 0, ran.said)
  assert(ran.said == "exit 0\nalpha\n", ran.said)
  local hidden = ChildPolicy.under(at.probe, policy, at.work,
    "run-isolated " .. at.probe .. " cat " .. at.extra .. "/e")
  assert(hidden.code == 0, hidden.said)
  assert(hidden.said:find("exit 1\n", 1, true) == 1 and
      hidden.said:find("No such file or directory", 1, true) ~= nil, hidden.said)
  -- Nor is the scratch it was built in, nor the first sandbox's rw directory.
  local scratch = ChildPolicy.under(at.probe, policy, at.work,
    "run-isolated " .. at.probe .. " present " .. at.scratch)
  assert(scratch.said:find("exit 1\n", 1, true) == 1 and scratch.said:find("not there", 1, true) ~= nil,
    scratch.said)
end

--- A start of the program's own with a network namespace of its own brings its
--- loopback up with a socket pair and the interface ioctls, which `nest` lets
--- through.
local function test_a_nested_sandbox_with_a_network_of_its_own_brings_its_loopback_up(tmp: string)
  local at = ChildPolicy.nest_placed(tmp)
  local ran = ChildPolicy.under(at.probe, nested(at), at.work,
    "run-looped " .. at.probe .. " print hi")
  assert(ran.code == 0 and ran.said == "exit 0\nhi\n", tostring(ran.code) .. ": " .. ran.said)
end

local function test_a_nested_sandbox_needs_nest(tmp: string)
  local at = ChildPolicy.nest_placed(tmp)
  -- What `nested` grants but `nest`.
  local grants = ChildPolicy.with(at.grants, { path = at.scratch, letters = "rwc" }, { path = at.extra, letters = "r" },
    { calls = "fork" })
  local ran = ChildPolicy.under(at.probe, { ...nested(at), grants = grants }, at.work,
    "run-isolated " .. at.probe .. " print hi")
  assert(ran.code == 0, ran.said)
  assert(ran.said:find("namespace was refused", 1, true), ran.said)
end
