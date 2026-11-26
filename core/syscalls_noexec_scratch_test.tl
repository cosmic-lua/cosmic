--- A scratch a start makes noexec, which only Linux has: elsewhere a start
--- that asks for one is refused ENOSYS before its mounts are checked, so
--- the module requires Linux. The check needs no sandbox of the host's,
--- since the start is refused as an argument before it makes one.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local process = require("cosmic.internal.process")

--- `nests`, since a worker held by a Landlock ruleset is refused a start
--- that unveils a root before the start reads its arguments
--- (build.confine's `forbid_running`).
Test.policy{
  grants = { { calls = "nest" } },
  requires = { "os:linux" },
}

--- A scratch the start makes noexec is refused beneath a target the root
--- already holds, and with an unveiling that shows all of /.
local function test_noexec_scratch_refuses_conflicting_mount_targets(tmp: string)
  for _, target in ipairs({ "/noexec", "/noexec/inside" }) do
    local pid, trouble, errno = process.spawn("/missing", { "/missing" }, nil, "/",
      nil, nil, nil, false, nil, { noexec_scratch = true, offline = true,
        unveil = { reads = { tmp }, at = { [tmp] = target } } })
    assert(pid == nil and errno == sys.EINVAL, trouble)
  end
  local pid, trouble, errno = process.spawn("/missing", { "/missing" }, nil, "/",
    nil, nil, nil, false, nil, { noexec_scratch = true, offline = true, unveil = { reads = { "/" } } })
  assert(pid == nil and errno == sys.EINVAL, trouble)
end
