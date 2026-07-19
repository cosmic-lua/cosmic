--- Linux capability bounding-set control for box assembly.
---
--- Typed wrapper over cosmo.unix prctl(2) capability operations. The
--- companion to cosmic.quicksand.proc: where proc.drop_privs clears the
--- *current* capability set (effective/permitted/inheritable via
--- capset), this module manipulates the capability *bounding set* — the
--- ceiling that limits which capabilities a process (or anything it
--- execve's) can ever hold. Dropping a capability from the bounding set
--- is irreversible and inherited across fork/exec, so a workload can
--- never regain it, even by executing a setuid or file-capability
--- binary.
---
--- Intended for the "after fork, before exec" window of a boxed child,
--- while it still holds CAP_SETPCAP in its user namespace. Call
--- drop_bounding() before proc.drop_privs (which clears CAP_SETPCAP and
--- would make subsequent PR_CAPBSET_DROP calls fail with EPERM).
---
--- Linux-only. On non-Linux hosts (or a cosmos build without the CAP_*
--- constants) the constants are nil; drop_bounding() is then a
--- successful no-op and supported() returns false.
local unix = require("cosmo.unix")
local errno = require("cosmic.errno")

--- The Linux capability names, matching unix.CAP_*. CAP_LAST_CAP is the
--- highest valid capability *number* (a bound, not a capability) and is
--- intentionally excluded. A name absent from the running cosmos build
--- resolves to nil and is skipped by the enumerating helpers.
local NAMES: {string} = {
  "CAP_AUDIT_CONTROL", "CAP_AUDIT_READ", "CAP_AUDIT_WRITE",
  "CAP_BLOCK_SUSPEND", "CAP_BPF", "CAP_CHECKPOINT_RESTORE", "CAP_CHOWN",
  "CAP_DAC_OVERRIDE", "CAP_DAC_READ_SEARCH", "CAP_FOWNER", "CAP_FSETID",
  "CAP_IPC_LOCK", "CAP_IPC_OWNER", "CAP_KILL", "CAP_LEASE",
  "CAP_LINUX_IMMUTABLE", "CAP_MAC_ADMIN", "CAP_MAC_OVERRIDE", "CAP_MKNOD",
  "CAP_NET_ADMIN", "CAP_NET_BIND_SERVICE", "CAP_NET_BROADCAST",
  "CAP_NET_RAW", "CAP_PERFMON", "CAP_SETFCAP", "CAP_SETGID", "CAP_SETPCAP",
  "CAP_SETUID", "CAP_SYSLOG", "CAP_SYS_ADMIN", "CAP_SYS_BOOT",
  "CAP_SYS_CHROOT", "CAP_SYS_MODULE", "CAP_SYS_NICE", "CAP_SYS_PACCT",
  "CAP_SYS_PTRACE", "CAP_SYS_RAWIO", "CAP_SYS_RESOURCE", "CAP_SYS_TIME",
  "CAP_SYS_TTY_CONFIG", "CAP_WAKE_ALARM",
}

--- Options for drop_bounding().
local record DropOptions
  keep: {string} -- capability names to retain in the bounding set
end

--- Resolve a capability name (e.g. "CAP_NET_RAW") to its integer number
--- for the running host, or nil + error if the name is unknown or the
--- host does not define it.
---
--- @param name string capability name
--- @return integer? capability number
--- @return string? error message
local function number_of(name: string): integer | nil, string
  if type(name) ~= "string" then
    return nil, "capability name must be a string"
  end
  local n = (unix as {string: any})[name] as integer
  if n == nil then
    return nil, "unknown capability: " .. name
  end
  return n
end

--- True when the capability bounding-set API is wired up on this host
--- (Linux with prctl + the CAP_* / PR_CAPBSET_* constants). A true
--- result means the calls exist; actually dropping from the bounding
--- set additionally requires CAP_SETPCAP at runtime.
---
--- @return boolean supported
local function supported(): boolean
  return unix.prctl ~= nil
  and unix.PR_CAPBSET_DROP ~= nil
  and unix.PR_CAPBSET_READ ~= nil
  and unix.CAP_LAST_CAP ~= nil
end

--- Build a capset(2) bitmask from capability names: bit N (1 << number)
--- is set for each named capability. Suitable for the effective /
--- permitted / inheritable arguments of unix.capset.
---
--- @param names {string} capability names
--- @return integer? bitmask
--- @return string? error message if a name is unknown
local function mask(names: {string}): integer | nil, string
  local m: integer = 0
  for _, name in ipairs(names) do
    local n, err = number_of(name)
    if n == nil then return nil, err end
    m = m | (1 << n)
  end
  return m
end

--- Read whether a capability is present in the current bounding set via
--- PR_CAPBSET_READ.
---
--- @param cap string capability name
--- @return boolean? true if in the bounding set, false if not
--- @return string? error message on failure
local function bounding_read(cap: string): boolean | nil, string
  local n, nerr = number_of(cap)
  if n == nil then return nil, nerr end
  local r, err = unix.prctl(unix.PR_CAPBSET_READ, n)
  if r == nil then
    return nil, errno.str(err, "PR_CAPBSET_READ " .. cap)
  end
  return r == 1
end

--- Remove a single capability from the current bounding set via
--- PR_CAPBSET_DROP. Irreversible and inherited across execve. Requires
--- CAP_SETPCAP.
---
--- @param cap string capability name
--- @return boolean true on success
--- @return string? error message on failure
local function bounding_drop(cap: string): boolean, string
  local n, nerr = number_of(cap)
  if n == nil then return false, nerr end
  local rc, err = unix.prctl(unix.PR_CAPBSET_DROP, n)
  if rc == nil then
    return false, errno.str(err, "PR_CAPBSET_DROP " .. cap)
  end
  return true
end

--- Drop every capability from the bounding set, optionally retaining
--- the names in `opts.keep`. Iterates 0..CAP_LAST_CAP calling
--- PR_CAPBSET_DROP. Irreversible and inherited across execve, so a
--- workload can never acquire a dropped capability afterwards — not
--- even by executing a setuid / file-capability binary.
---
--- Must run while the caller still holds CAP_SETPCAP (e.g. immediately
--- after unshare(CLONE_NEWUSER) with a uid map, before proc.drop_privs
--- clears the capability set). A cap number the kernel does not know
--- (EINVAL) is skipped; ENOSYS ends the sweep successfully. On a host
--- without the CAP_* constants (non-Linux) this is a successful no-op.
---
--- @param opts DropOptions? optional keep-set
--- @return boolean true on success
--- @return string? error message on failure
local function drop_bounding(opts?: DropOptions): boolean, string
  local last = unix.CAP_LAST_CAP
  if last == nil then
    -- No capability constants (non-Linux, or a cosmos without them):
    -- there is nothing to drop.
    return true
  end
  local keep: {integer: boolean} = {}
  if opts and opts.keep then
    for _, name in ipairs(opts.keep) do
      local n, err = number_of(name)
      if n == nil then return false, err end
      keep[n] = true
    end
  end
  for c = 0, last do
    if not keep[c] then
      local rc, err, eno = unix.prctl(unix.PR_CAPBSET_DROP, c)
      if rc == nil then
        if errno.is(eno, "EINVAL") then
          -- Capability number unknown to this kernel; skip it.
        elseif errno.is(eno, "ENOSYS") then
          -- Capabilities unsupported on this host; done.
          return true
        else
          return false, errno.str(err,
            "PR_CAPBSET_DROP " .. tostring(c))
        end
      end
    end
  end
  return true
end

local record CapsModule
  NAMES: {string}
  supported: function(): boolean
  number_of: function(name: string): integer | nil, string
  mask: function(names: {string}): integer | nil, string
  bounding_read: function(cap: string): boolean | nil, string
  bounding_drop: function(cap: string): boolean, string
  drop_bounding: function(opts?: DropOptions): boolean, string
end

local M: CapsModule = {
  NAMES = NAMES,
  supported = supported,
  number_of = number_of,
  mask = mask,
  bounding_read = bounding_read,
  bounding_drop = bounding_drop,
  drop_bounding = drop_bounding,
}

return M
