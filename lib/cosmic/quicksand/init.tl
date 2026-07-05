--- Network + filesystem process isolation primitives.
---
--- cosmic.quicksand is the umbrella for Linux-specific box assembly:
--- network-namespace setup (cosmic.quicksand.netns), an allowlist
--- HTTP/CONNECT proxy (cosmic.quicksand.proxy), and after-fork process
--- primitives (cosmic.quicksand.proc). Pair it with the top-level
--- `cosmic.landlock`, `cosmic.pledge`, and `cosmic.unveil` modules to
--- compose a full sandbox.
---
--- This module (the umbrella) probes the host for fine-grained feature
--- availability so callers can fail fast with a specific reason instead
--- of bailing partway through setup on ENOSYS. It also re-exports the
--- declarative Box builder (cosmic.quicksand.box) that composes the
--- primitives into a single run() call.
---
--- Linux-only at runtime. Non-Linux hosts see `capabilities().linux ==
--- false` and all submodule calls return ENOSYS-shaped errors.
local cosmo = require("cosmo")
local unix = require("cosmo.unix")
local box = require("cosmic.quicksand.box")
local caps = require("cosmic.quicksand.caps")
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
  pledge: boolean -- unix.pledge non-ENOSYS (Linux via seccomp + OpenBSD)
  unveil: boolean -- unix.unveil non-ENOSYS (OpenBSD, or Linux+Landlock)
  caps: boolean -- prctl capability bounding-set API available (PR_CAPBSET_*)
end

local record QuicksandModule
  capabilities: function(): Capabilities
  is_supported: function(): boolean
  probe: function(fn: any): boolean
  Box: any -- re-export of cosmic.quicksand.box
end

--- Probe a pledge/unveil-style binding with a no-op call: available
--- when the call succeeds, or fails with anything other than ENOSYS
--- (a policy error still proves the syscall is wired up). A nil binding
--- (not exported on this host) reports unavailable.
---
--- This classification is only correct because a failed `unix.*` call now
--- returns a real `Errno` in its second slot (the Phase 0 annotation fix):
--- before it, the error was swallowed and every probe reported available
--- (fail-open, audit §2.3). Exported so the classifier is unit-testable
--- against synthetic ENOSYS / policy-error / success returns.
---
--- @param fn any the binding to probe (e.g. `unix.pledge`), or nil
--- @return boolean true when the syscall is wired up on this host
local function probe(fn: any): boolean
  if not fn then return false end
  local call = fn as function(any, any): any, Errno
  local ok, err = call(nil, nil)
  if ok then return true end
  if err and err.errno and err:errno() == unix.ENOSYS then return false end
  return true
end

--- Landlock availability: the kernel reports its ABI version from a
--- flag-less landlock_create_ruleset call; >= 1 means enforceable.
local function probe_landlock(): boolean
  local abi = unix.landlock_create_ruleset()
  return abi ~= nil and abi >= 1
end

local cached: Capabilities = nil

--- Returns a cached Capabilities record for the current host.
---
--- Higher-level helpers use this to fail fast with a specific reason
--- rather than bail out on ENOSYS partway through a setup sequence.
--- Repeated calls return the same table.
local function capabilities(): Capabilities
  if cached then return cached end
  local host = cosmo.GetHostOs()
  local is_linux = host == "LINUX"
  local has_landlock = is_linux and probe_landlock()
  cached = {
    linux = is_linux,
    user_ns = is_linux and unix.CLONE_NEWUSER ~= nil,
    mount_ns = is_linux and unix.CLONE_NEWNS ~= nil,
    net_ns = is_linux and unix.CLONE_NEWNET ~= nil,
    uts_ns = is_linux and unix.CLONE_NEWUTS ~= nil,
    pid_ns = is_linux and unix.CLONE_NEWPID ~= nil,
    pivot_root = is_linux and unix.pivot_root ~= nil,
    cap_net_admin = is_linux and unix.geteuid ~= nil and unix.geteuid() == 0,
    landlock = has_landlock,
    pledge = probe(unix.pledge),
    -- unveil is DERIVED, never probed: for unveil, unix.unveil(nil, nil) is
    -- the commit call -- probing it would lock this very process into a
    -- deny-all sandbox. cosmo implements unveil via Landlock on Linux, so it
    -- is available exactly when Landlock is; OpenBSD has it natively.
    unveil = has_landlock or host == "OPENBSD",
    caps = is_linux and caps.supported(),
  }
  return cached
end

--- True when the namespace-based box primitives can do real work
--- (Linux host with net + mount namespaces). Prefer capabilities()
--- for fine-grained checks.
local function is_supported(): boolean
  local c = capabilities()
  return c.linux and c.net_ns and c.mount_ns
end

local M: QuicksandModule = {
  capabilities = capabilities,
  is_supported = is_supported,
  probe = probe,
  Box = box,
}

return M
