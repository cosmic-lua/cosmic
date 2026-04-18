--- Network + filesystem process isolation primitives.
---
--- cosmic.quicksand is the umbrella for Linux-specific jail assembly:
--- network-namespace setup (cosmic.quicksand.netns), an allowlist
--- HTTP/CONNECT proxy (cosmic.quicksand.proxy), and after-fork process
--- primitives (cosmic.quicksand.proc). Pair it with the top-level
--- `cosmic.landlock`, `cosmic.pledge`, and `cosmic.unveil` modules to
--- compose a full sandbox.
---
--- This module (the umbrella) exposes a capability probe so callers
--- can fail fast with a specific reason instead of bailing partway
--- through setup on ENOSYS.
---
--- Linux-only at runtime. Non-Linux hosts see `capabilities().linux ==
--- false` and all submodule calls return ENOSYS-shaped errors.
local sandbox = require("cosmo.sandbox")
local unix = require("cosmo.unix")
local Errno = require("cosmic.errno").Errno

--- Fine-grained feature availability on the current host.
--- Every field is a boolean. Higher-level helpers use these to fail
--- fast with a specific reason instead of bailing out on ENOSYS
--- partway through a setup sequence.
local record Capabilities
  linux: boolean -- host is Linux
  user_ns: boolean -- CLONE_NEWUSER available (unprivileged usernet)
  mount_ns: boolean -- CLONE_NEWNS available
  net_ns: boolean -- CLONE_NEWNET available
  uts_ns: boolean -- CLONE_NEWUTS available (for hostname isolation)
  pid_ns: boolean -- CLONE_NEWPID available
  pivot_root: boolean -- unix.pivot_root exported
  cap_net_admin: boolean -- holds CAP_NET_ADMIN (e.g. effective uid 0)
  landlock: boolean -- kernel advertises landlock ABI >= 1
  pledge: boolean -- unix.pledge available (Linux + OpenBSD)
  unveil: boolean -- unix.unveil non-ENOSYS (OpenBSD-only)
end

local record QuicksandModule
  capabilities: function(): Capabilities
  is_supported: function(): boolean
end

-- Probe whether unix.pledge / unix.unveil return ENOSYS on this host.
-- Calling them with nil,nil is a no-op on OpenBSD and returns ENOSYS
-- elsewhere, which is what we want for a capability probe.
local function pledge_available(): boolean
  if not unix.pledge then return false end
  local ok, err = unix.pledge(nil, nil) as(boolean, any)
  if ok then return true end
  if not err then return false end
  return (err as Errno):name() ~= "ENOSYS"
end

local function unveil_available(): boolean
  if not unix.unveil then return false end
  local ok, err = unix.unveil(nil, nil) as(boolean, any)
  if ok then return true end
  if not err then return false end
  return (err as Errno):name() ~= "ENOSYS"
end

local cached: Capabilities = nil

--- Returns a cached Capabilities record for the current host.
---
--- Higher-level helpers use this to fail fast with a specific reason
--- rather than bail out on ENOSYS partway through a setup sequence.
--- Repeated calls return the same table.
local function capabilities(): Capabilities
  if cached then return cached end
  local raw = sandbox.capabilities() as {string: boolean}
  cached = {
    linux = raw.linux or false,
    user_ns = raw.user_ns or false,
    mount_ns = raw.mount_ns or false,
    net_ns = raw.net_ns or false,
    uts_ns = raw.uts_ns or false,
    pid_ns = raw.pid_ns or false,
    pivot_root = raw.pivot_root or false,
    cap_net_admin = raw.cap_net_admin or false,
    landlock = raw.landlock or false,
    pledge = pledge_available(),
    unveil = unveil_available(),
  }
  return cached
end

--- True when the namespace-based jail primitives can do real work
--- (Linux host with net + mount namespaces). Kept for backwards
--- compatibility with cosmo.sandbox.is_supported(); prefer
--- capabilities() for fine-grained checks.
local function is_supported(): boolean
  local c = capabilities()
  return c.linux and c.net_ns and c.mount_ns
end

local M: QuicksandModule = {
  capabilities = capabilities,
  is_supported = is_supported,
}

return M
