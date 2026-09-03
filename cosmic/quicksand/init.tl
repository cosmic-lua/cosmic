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
--- of bailing partway through setup on ENOSYS. It also fronts the
--- declarative Box builder (cosmic.quicksand.box): quicksand.new(opts)
--- composes the primitives into a single box:run() call.
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
local landlock = require("cosmic.sandbox.landlock")

--- Fine-grained feature availability on the current host; the record
--- definition lives in cosmic.quicksand.types so the Box layers name
--- the same nominal type.
local type Capabilities = types.Capabilities

--- The box instance and options records, re-exported so callers name
--- them from the umbrella: `quicksand.Box`, `quicksand.BoxOptions`.
local type Box = box.Box
local type BoxOptions = box.BoxOptions

local record QuicksandModule
  type Capabilities = Capabilities
  type Box = Box
  type BoxOptions = BoxOptions
  --- Build a Box from an options table.
  new: function(opts?: BoxOptions): Box | nil, string
  --- Compose Box options left-to-right (lists concat + dedupe, maps
  --- per-key later wins, scalars later wins).
  merge: function(...: BoxOptions): BoxOptions
  capabilities: function(): Capabilities
  is_supported: function(): boolean
  --- Internal, exported for its own unit tests: pure decision function
  --- over a binding value; never syscalls.
  probe: function(fn: any): boolean
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
  -- A varargs return, because this probe is handed an ARBITRARY
  -- binding: it reads slot 1 and the numeric errno, and has no business
  -- declaring how many slots some other binding returns.
  local call = fn as function(any, any): any ... -- cast: runtime capability probe: fn is any, an arbitrary binding
  local ok, _, eno = call(nil, nil)
  if ok then return true end
  if errno.is_code(eno, "ENOSYS") then return false end
  return true
end

--- Landlock availability, delegated to cosmic.sandbox.landlock's
--- cached probe — the one place Landlock ABI knowledge lives,
--- shared with cosmic.sandbox.unveil.
local function probe_landlock(): boolean
  return landlock.available()
end

--- True when this host's Landlock ABI is >= 4 — the per-port TCP
--- rights (NET_BIND_TCP / NET_CONNECT_TCP) that back the sandbox `net`
--- section. Delegates to the same cached abi() probe as probe_landlock,
--- so no extra syscall.
local function probe_landlock_net(): boolean
  return (landlock.abi() or 0) >= 4
end

--- Attempt unshare(flags) followed by the uid_map / gid_map writes in a
--- scratch child — exactly the setup sequence Box:run's supervisor
--- performs for whatever flags it ends up using — and report the
--- outcome over a pipe. unshare is irreversible for the caller, so the
--- attempt must never run in this process. Any probe failure (pipe,
--- fork, unshare, map writes) reports unavailable — fail-closed.
---
--- Captures this process's real uid/gid BEFORE forking, not after
--- unsharing in the child: once CLONE_NEWUSER takes effect, uid_map is
--- still empty, so geteuid()/getegid() read back as the overflow uid/gid
--- (nobody), not this process's real host identity, and a mapping built
--- from that value is rejected with EPERM regardless of what this probe
--- is trying to measure.
---
--- @param flags integer the unshare(2) flags to attempt
--- @return boolean true when the scratch child's unshare + map writes
---   both succeeded
local function probe_unshare(flags: integer): boolean
  local host_uid = unix.geteuid()
  local host_gid = unix.getegid()
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
      ok = qproc.setup_userns_maps(host_uid, host_gid)
    end
    unix.write(wfd, ok and "1" or "0")
    unix.exit(0) -- exits: forked probe child; the answer is on the pipe
  end
  unix.close(wfd)
  local b = unix.read(rfd, 1)
  unix.close(rfd)
  unix.wait(pid)
  return b == "1"
end

--- Probe the Box namespace setup in two tiers, so a host that
--- restricts network namespaces specifically (netns disabled while
--- plain user namespaces stay allowed, a max_net_namespaces limit, a
--- seccomp filter on the clone flags, ...) is told apart from one
--- where user namespaces are blocked outright.
---
--- Tries the full trio first (CLONE_NEWUSER | CLONE_NEWNET |
--- CLONE_NEWNS — exactly what Box:run's supervisor unshares). A trio
--- success proves both tiers at once, so the second probe only runs on
--- trio failure. On failure, retries with CLONE_NEWNET dropped — the
--- same user+mount subset Box:run's clone_flags falls back to when the
--- Landlock net tier covers containment instead — which tells "netns
--- specifically is restricted" apart from "user namespaces don't work
--- at all". The single combined probe this replaced conflated the two:
--- any host-side reason netns couldn't start failed the whole
--- unshare() call, which surfaced as user_ns = false even on a host
--- where plain user+mount namespaces were fine.
---
--- CLONE_NEWUSER exists as a compile-time constant on every Linux
--- build, but hosts routinely disable unprivileged user namespaces
--- (sysctls, seccomp, AppArmor), and others allow the unshare while
--- blocking the /proc/self/*_map writes; testing the constant reported
--- user_ns = true on such hosts and Box:run then failed partway
--- through setup with EPERM — the same reasoning applies to net_ns,
--- which used to be a bare CLONE_NEWNET-exists check.
---
--- @return boolean true when USER|NS works, whether or not the trio below does
--- @return boolean true when the full USER|NET|NS trio works here
local function probe_ns(): boolean, boolean
  if unix.CLONE_NEWUSER == nil or unix.CLONE_NEWNS == nil then
    return false, false
  end
  local base = (unix.CLONE_NEWUSER) | (unix.CLONE_NEWNS)
  if unix.CLONE_NEWNET == nil then
    return probe_unshare(base), false
  end
  local trio = base | (unix.CLONE_NEWNET)
  if probe_unshare(trio) then
    return true, true
  end
  return probe_unshare(base), false
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
  -- Two distinct scratch-child probes, not one: user_ns and net_ns must
  -- be free to disagree (see probe_ns), so both come from that single
  -- call rather than user_ns from probe_ns() and net_ns from a
  -- compile-time constant check.
  local ns_user_ok = false
  local ns_net_ok = false
  if is_linux then
    ns_user_ok, ns_net_ok = probe_ns()
  end
  cached = {
    linux = is_linux,
    user_ns = ns_user_ok,
    mount_ns = is_linux and unix.CLONE_NEWNS ~= nil,
    net_ns = ns_net_ok,
    uts_ns = is_linux and unix.CLONE_NEWUTS ~= nil,
    pid_ns = is_linux and unix.CLONE_NEWPID ~= nil,
    pivot_root = is_linux and unix.pivot_root ~= nil,
    cap_net_admin = is_linux and unix.geteuid ~= nil and unix.geteuid() == 0,
    landlock = has_landlock,
    landlock_net = is_linux and probe_landlock_net(),
    pledge = probe(unix.pledge),
    -- unveil is DERIVED, never probed: for unveil, unix.unveil(nil, nil) is
    -- the commit call -- probing it would lock this very process into a
    -- deny-all sandbox. cosmo implements unveil via Landlock on Linux, so it
    -- is available exactly when Landlock is; OpenBSD has it natively.
    unveil = has_landlock or host == "OPENBSD",
    caps = is_linux and caps.is_supported(),
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
  new = box.new,
  merge = box.merge,
  capabilities = capabilities,
  is_supported = is_supported,
  probe = probe,
}

return M
