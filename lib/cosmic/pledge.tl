--- Restrict the system calls available to the current process.
---
--- Pledging is irreversible: once applied, most system calls become
--- unavailable. On Linux, disallowed calls return EPERM; on OpenBSD the
--- kernel terminates the process. Use pledge in conjunction with
--- `cosmic.unveil` to also narrow filesystem visibility.
---
--- The API is fail-closed: on hosts where the libc cannot enforce a
--- pledge (anything other than Linux or OpenBSD), `apply` returns
--- `false, "pledge unsupported on this host"` instead of reporting a
--- sandbox that does not exist. Callers that prefer the old fail-open
--- behavior opt in explicitly with `best_effort = true`, or branch on
--- `available()` themselves.
---
--- Common promise groups:
---
---   stdio     standard I/O (read, write, close)
---   rpath     read-only path operations
---   wpath     write operations on paths
---   cpath     create and remove paths
---   flock     file locking
---   tty       terminal operations (isatty, tiocgwinsz, etc.)
---   inet      IPv4 / IPv6 sockets
---   unix      UNIX-domain sockets
---   proc      fork, vfork, kill, wait, etc.
---   exec      execve
---   unveil    permit subsequent unveil calls
local unix = require("cosmo.unix")
local errno = require("cosmic.errno")

--- Options for `apply`. `exec` sets the promises children keep after
--- execve. `best_effort` turns an unsupported host into a successful
--- no-op instead of an error — the explicit fail-open escape hatch.
local record ApplyOpts
  exec: string
  best_effort: boolean
end

local avail: boolean = nil

--- True when pledge(2) is actually enforceable on this host (Linux via
--- seccomp, OpenBSD natively). Probed once with a no-op
--- `unix.pledge(nil, nil)` call — the libc fails that probe closed with
--- ENOSYS where enforcement is impossible — and cached. A non-ENOSYS
--- failure (e.g. EPERM from an outer filter) still proves the syscall
--- is wired up.
---
--- @return boolean True when a pledge can be enforced
local function available(): boolean
  if avail ~= nil then return avail end
  if unix.pledge == nil then
    avail = false
    return avail
  end
  local ok, _, eno = unix.pledge(nil, nil)
  if ok then
    avail = true
  elseif errno.is(eno, "ENOSYS") then
    avail = false
  else
    avail = true
  end
  return avail
end

--- Apply a pledge to the current process.
---
--- The call is irreversible; subsequent invocations may only narrow the
--- set of permitted promises. Fail-closed: on a host where pledge
--- cannot be enforced this returns `false, "pledge unsupported on this
--- host"` rather than succeeding without a sandbox; pass
--- `best_effort = true` to treat that case as a successful no-op.
---
--- @param promises string Space-separated promise groups for this process
--- @param opts ApplyOpts? `exec` promises after execve; `best_effort` escape hatch
--- @return boolean True on success
--- @return string? Error message on failure
local function apply(promises: string, opts?: ApplyOpts): boolean, string
  if not available() then
    if opts and opts.best_effort then return true end
    return false, "pledge unsupported on this host"
  end
  local ok, err = unix.pledge(promises, opts and opts.exec)
  if not ok then
    return false, errno.str(err, "pledge")
  end
  return true
end

local record PledgeModule
  type ApplyOpts = ApplyOpts
  apply: function(promises: string, opts?: ApplyOpts): boolean, string
  available: function(): boolean
end

local M: PledgeModule = {
  apply = apply,
  available = available,
}

return M
