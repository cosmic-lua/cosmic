--- cosmo.sandbox: Linux process-isolation primitives.
---
--- This module is the entry point for the Cosmopolitan Lua sandbox
--- library. The pieces it exposes are thin wrappers around `unix.*`
--- syscalls plus higher-level helpers:
---
---     cosmo.sandbox.netns     network namespace helpers
---     cosmo.sandbox.fs        filesystem (bind/tmpfs/pivot) helpers
---     cosmo.sandbox.proc      process setup (no_new_privs, drop_privs,
---                             become_init supervisor, fork barrier)
---     cosmo.sandbox.landlock  unprivileged filesystem allowlist
---     cosmo.sandbox.proxy     HTTP CONNECT + plain-HTTP allowlist proxy
---
--- All helpers and their underlying `unix.*` syscalls return
--- `nil, unix.Errno` on failure (matching the rest of cosmo's lunix
--- conventions). Callers can `:errno()` the Errno object for the
--- integer code or `tostring()` for a human-readable string.
---
--- The whole library is Linux-only. On non-Linux hosts the syscalls
--- return ENOSYS and `is_supported()` returns false.
---
--- Status: `unix.*` wrappers are the stable API tier; everything under
--- `cosmo.sandbox.*` is experimental and may evolve based on usage.

local unix = require "unix"
local cosmo = require "cosmo"

local M = {
  _VERSION = "0.0.3",
}

--- cosmo.sandbox.capabilities() → table
---
--- Probe the host for fine-grained feature availability. Each field
--- is a boolean. The probe is cached after the first call so repeated
--- queries are free.
---
--- Fields:
---   linux          host is Linux (cosmo.GetHostOs() == "LINUX")
---   user_ns        unshare(CLONE_NEWUSER) works without root
---   mount_ns       CLONE_NEWNS is defined (kernel supports it)
---   net_ns         CLONE_NEWNET is defined
---   uts_ns         CLONE_NEWUTS is defined (for sethostname isolation)
---   pid_ns         CLONE_NEWPID is defined
---   pivot_root     unix.pivot_root is exported by lunix
---   cap_net_admin  geteuid() == 0 (veth pair creation needs root or
---                  a network-namespace that owns its own netlink)
---   landlock       kernel advertises landlock ABI >= 1 (Linux ≥ 5.13)
---   pledge         unix.pledge is exported and does not ENOSYS on a
---                  no-op call (true on Linux via seccomp and on
---                  OpenBSD via the native syscall)
---   unveil         unix.unveil is exported and does not ENOSYS on a
---                  no-op call (true on OpenBSD, and on Linux when
---                  Landlock-backed unveil is available)
---
--- Higher-level helpers use these to fail fast with a specific reason
--- rather than bail out on ENOSYS partway through a setup sequence.
local function probe_nop(fn)
  if not fn then return false end
  local ok, err = fn(nil, nil)
  if ok then return true end
  if err and err.errno and err:errno() == unix.ENOSYS then return false end
  return true
end
local _caps
function M.capabilities()
  if _caps then return _caps end
  local is_linux = cosmo.GetHostOs() == "LINUX"
  local ll_ok = false
  if is_linux and unix.landlock_create_ruleset then
    local abi = unix.landlock_create_ruleset()
    ll_ok = type(abi) == "number" and abi >= 1
  end
  _caps = {
    linux         = is_linux,
    user_ns       = is_linux and unix.CLONE_NEWUSER ~= nil,
    mount_ns      = is_linux and unix.CLONE_NEWNS   ~= nil,
    net_ns        = is_linux and unix.CLONE_NEWNET  ~= nil,
    uts_ns        = is_linux and unix.CLONE_NEWUTS  ~= nil,
    pid_ns        = is_linux and unix.CLONE_NEWPID  ~= nil,
    pivot_root    = is_linux and unix.pivot_root    ~= nil,
    cap_net_admin = is_linux and unix.geteuid and unix.geteuid() == 0,
    landlock      = ll_ok,
    pledge        = probe_nop(unix.pledge),
    unveil        = probe_nop(unix.unveil),
  }
  return _caps
end

--- cosmo.sandbox.is_supported() → bool
---
--- True when the primitives in this module can do real work — i.e.
--- we're running on Linux and the namespace bindings are linked in.
--- Kept for backwards compatibility; prefer capabilities() for
--- fine-grained feature detection.
function M.is_supported()
  local c = M.capabilities()
  return c.linux and c.net_ns and c.mount_ns
end

return M
