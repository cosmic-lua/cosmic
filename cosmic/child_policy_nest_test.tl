--- [`Child.start`]'s `policy` with the `nest` promise (cosmic/child.tl): a
--- program that builds a sandbox of its own, in a root of its own, held
--- by that root instead of Landlock, which the kernel would have refuse
--- every mount. The kernel's own verdict on live children: a fake
--- ([`cosmic.fake`]) started under the policy. They need
--- a host that lets a sandbox nest (`requires`): where the platform has none
--- they are not applicable, and where this host gives no seccomp each skips
--- itself (Test.skip). The refusals that come before a child, which hold on
--- every platform, are in cosmic/child_policy_anywhere_test.tl; what a
--- program inside makes of the namespace and mount calls themselves, in
--- cosmic/child_policy_nest_calls_test.tl; and what Landlock holds beside a
--- root (a sandbox the fake starts of its own, a directory handed
--- without `nest`), in cosmic/child_policy_nest_landlock_test.tl, which
--- requires it.

local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local ChildPolicy = require("build.child_policy_fixture")

--- The temporary directory, which a start's root is built in, and `nests`,
--- since the sandboxes this test makes are roots a worker held by a
--- Landlock ruleset cannot build.
Test.policy{
  env = { "TMPDIR" },
  grants = { { calls = "nest" } },
  requires = { "nest" },
}

--- The mount at `point` in a /proc/self/mountinfo `text`: its per-mount options.
local function options_at(text: string, point: string): string?
  for line in text:gmatch("[^\n]+") do
    local left = line:match("^(.-) %- ")
    if left ~= nil then
      local fields: mut {string} = {}
      for word in left:gmatch("%S+") do fields[#fields + 1] = word end
      if fields[5] == point then return fields[6] end
    end
  end
  return nil
end

local function test_nest_holds_files_by_the_root_alone(tmp: string)
  local at = ChildPolicy.nest_placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "file" }, grants = ChildPolicy.with(at.grants, { calls = "nest" }) }
  local read = ChildPolicy.under(at.probe, policy, at.work, "cat ro/a")
  assert(read.code == 0 and read.said == "alpha\n", tostring(read.code) .. ": " .. read.said)
  -- Not granted, so not there; read-only where not granted `w`.
  local other = ChildPolicy.under(at.probe, policy, at.work, "cat " .. at.extra .. "/e")
  assert(other.code == 1 and other.said:find("No such file or directory", 1, true) ~= nil, other.said)
  local ro = ChildPolicy.under(at.probe, policy, at.work, "create ro/b x")
  assert(ro.code == 1 and ro.said:find("Read-only file system", 1, true) ~= nil, ro.said)
  local rw = ChildPolicy.under(at.probe, policy, at.work, "create rw/b x && cat rw/b")
  assert(rw.code == 0 and rw.said == "x\n", tostring(rw.code) .. ": " .. rw.said)
  -- What Landlock refused to run is held by the mount: a grant without `x`
  -- is noexec, read-only or not, and the program's own is not.
  local mounts = ChildPolicy.under(at.probe, policy, at.work, "cat /proc/self/mountinfo")
  assert(mounts.code == 0, mounts.said)
  local read_only = options_at(mounts.said, at.work)
  assert(read_only ~= nil and read_only:find("ro", 1, true) ~= nil and read_only:find("noexec", 1, true) ~= nil,
    tostring(read_only))
  local writable = options_at(mounts.said, at.work .. "/rw")
  assert(writable ~= nil and writable:find("rw", 1, true) ~= nil and writable:find("noexec", 1, true) ~= nil,
    tostring(writable))
  local program = options_at(mounts.said, at.probe)
  assert(program ~= nil and not program:find("noexec", 1, true), tostring(program))
  local held = ChildPolicy.under(at.probe, policy, at.work, "status-field Seccomp")
  assert(held.said:find("Seccomp:\t2", 1, true), held.said)
end

local function test_nest_hands_no_directory_nor_half_open_file(tmp: string)
  local at = ChildPolicy.nest_placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "file" }, grants = ChildPolicy.with(at.grants, { calls = "nest" }) }
  local dir = assert(sys.open(at.extra, sys.O_RDONLY))
  local reading = assert(sys.open(at.extra .. "/e", sys.O_RDONLY))
  local writing = assert(sys.open(at.extra .. "/e", sys.O_WRONLY))
  local both = assert(sys.open(at.extra .. "/e", sys.O_RDWR))
  local function start(held: Sandbox.Policy, fds: {integer:integer | string}): string
    local handle, why = Child.start({ at.probe, "print hi" }, { timeout_ns = Child.FOREVER, policy = held, cwd = at.work, fds = fds })
    if handle ~= nil then
      local _, _ = handle:close()
      return ""
    end
    return tostring(why)
  end
  local why = start(policy, { [3] = dir })
  assert(why:find("descriptor 3", 1, true) and why:find("directory", 1, true) and
      why:find("nest", 1, true), why)
  local shut = start(policy, { [4] = reading })
  assert(shut:find("descriptor 4", 1, true) and shut:find("reading and writing", 1, true), shut)
  assert(start(policy, { [5] = writing }):find("descriptor 5", 1, true))
  assert(start(policy, { [3] = both }) == "")
  -- A pipe has no path to reach.
  assert(start(policy, { [3] = "capture" }) == "")
  sys.close(dir)
  sys.close(reading)
  sys.close(writing)
  sys.close(both)
end

--- A descriptor this runtime retains of its own -- the artifact and the core
--- a relaunch hands on -- is refused to a `nest` child as a half-open file
--- is, naming it, where stat-ing it raised.
local function test_nest_refuses_the_runtimes_own_descriptors_rather_than_raising(tmp: string)
  local launched, _ = Proc.relaunch()
  if launched == nil or next(launched.fds) == nil then
    Test.skip("this start retains no descriptor of the runtime's own to refuse")
    return
  end
  local at = ChildPolicy.nest_placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "file" }, grants = ChildPolicy.with(at.grants, { calls = "nest" }) }
  local handle, why = Child.start({ at.probe, "print hi" },
    { timeout_ns = Child.FOREVER, policy = policy, cwd = at.work, fds = launched.fds })
  if handle ~= nil then
    local _, _ = handle:close()
  end
  assert(handle == nil and why.message:find("retains of its own", 1, true) ~= nil and -- checked: or_mix
      why.message:find("nest", 1, true), tostring(why))
end
