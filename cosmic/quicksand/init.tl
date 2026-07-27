--- Network + filesystem process isolation primitives.
---
--- cosmic.quicksand is the umbrella for Linux-specific box assembly:
--- network-namespace setup (cosmic.quicksand.netns), an allowlist
--- HTTP/CONNECT proxy (cosmic.quicksand.proxy), and after-fork process
--- primitives (cosmic.quicksand.proc). The boxed workload applies the
--- `cosmic.sandbox` facade (landlock + pledge) for its fs and syscall
--- policy; use that module directly to sandbox in-process.
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
local qproc = require("cosmic.quicksand.proc")
local types = require("cosmic.quicksand.types")
local errno = require("cosmic.errno")

--- Fine-grained feature availability on the current host; the record
--- definition lives in cosmic.quicksand.types so the Box layers name
--- the same nominal type.
local type Capabilities = types.Capabilities

--- The typed surface of the re-exported Box builder (the box module's
--- own record type is not directly nameable from here).
local record BoxIface
  new: function(opts?: box.BoxOptions): box.Box | nil, string
  merge: function(...: box.BoxOptions): box.BoxOptions
end

local record QuicksandModule
  type Capabilities = Capabilities
  capabilities: function(): Capabilities
  is_supported: function(): boolean
  probe: function(fn: any): boolean
  probe_ns: function(): boolean
  Box: BoxIface -- re-export of cosmic.quicksand.box
end

--- Probe a pledge/unveil-style binding with a no-op call: available
--- when the call succeeds, or fails with anything other than ENOSYS
--- (a policy error still proves the syscall is wired up). A nil binding
--- (not exported on this host) reports unavailable.
---
--- This classification is only correct because a failed `unix.*` call
--- reports its error: the binding returns `nil, err (string), errno
--- (number)`, and the numeric errno in that third slot is what
--- classifies ENOSYS. Without it the error is swallowed, the ENOSYS
--- branch is unreachable, and every probe reports available — fail-open,
--- in a capability check. Exported so the classifier is unit-testable
--- against synthetic ENOSYS / policy-error / success returns.
---
--- @param fn any the binding to probe (e.g. `unix.pledge`), or nil
--- @return boolean true when the syscall is wired up on this host
local function probe(fn: any): boolean
  if not fn then return false end
  local call = fn as function(any, any): any, string, integer -- cast: function shape
  local ok, _, eno = call(nil, nil)
  if ok then return true end
  if errno.is(eno, "ENOSYS") then return false end
  return true
end

--- Landlock availability: the kernel reports its ABI version from a
--- flag-less landlock_create_ruleset call; >= 1 means enforceable.
local function probe_landlock(): boolean
  local abi = unix.landlock_create_ruleset()
  return abi ~= nil and abi >= 1
end

--- Probe whether the Box namespace trio can actually be entered: a
--- scratch child attempts unshare(CLONE_NEWUSER | CLONE_NEWNET |
--- CLONE_NEWNS) followed by the uid_map / gid_map writes — exactly the
--- setup sequence Box:run's supervisor performs — and reports the
--- outcome over a pipe. unshare is irreversible for the caller, so the
--- attempt must never run in this process.
---
--- CLONE_NEWUSER exists as a compile-time constant on every Linux
--- build, but hosts routinely disable unprivileged user namespaces
--- (sysctls, seccomp, AppArmor), and others allow the unshare while
--- blocking the /proc/self/*_map writes; testing the constant reported
--- user_ns = true on such hosts and Box:run then failed partway
--- through setup with EPERM. Any probe failure (pipe, fork, unshare,
--- map writes) reports unavailable — fail-closed.
---
--- @return boolean true when the Box userns setup sequence works here
local function probe_ns(): boolean
  if unix.CLONE_NEWUSER == nil or unix.CLONE_NEWNET == nil
  or unix.CLONE_NEWNS == nil then
    return false
  end
  local flags = (unix.CLONE_NEWUSER)
  | (unix.CLONE_NEWNET)
  | (unix.CLONE_NEWNS)
  local r, w = unix.pipe(unix.O_CLOEXEC)
  if not r then return false end
  local rfd = r
  local wfd = w
  local pid = unix.fork()
  if pid == nil then
    unix.close(rfd)
    unix.close(wfd)
    return false
  end
  if pid == 0 then
    local ok = unix.unshare(flags)
    if ok then
      ok = qproc.setup_userns_maps(nil, nil)
    end
    unix.write(wfd, ok and "1" or "0")
    unix.exit(0)
  end
  unix.close(wfd)
  local b = unix.read(rfd, 1)
  unix.close(rfd)
  unix.wait(pid)
  return b == "1"
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
    user_ns = is_linux and probe_ns(),
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
  probe_ns = probe_ns,
  Box = box,
}

return M
