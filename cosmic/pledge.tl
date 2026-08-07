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
--- sandbox that does not exist. Callers that want fail-open behavior
--- opt in explicitly with `best_effort = true`, or branch on
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
local seal_coverage = require("cosmic._seal_coverage").seal_coverage

--- The promise groups the libc accepts, as a Teal enum so typed callers
--- get promise names checked at compile time. `apply` still takes the
--- space-separated string pledge(2) expects; build it from enum values
--- (e.g. `table.concat(list, " ")`) to keep the checking.
local enum Promise
  "stdio"
  "rpath"
  "wpath"
  "cpath"
  "dpath"
  "flock"
  "fattr"
  "tty"
  "inet"
  "unix"
  "dns"
  "recvfd"
  "sendfd"
  "proc"
  "exec"
  "id"
  "unveil"
  "settime"
  "prot_exec"
  "vminfo"
  "tmppath"
  "anet"
  "chown"
end

--- Every Promise value, for runtime validation of promise strings
--- (Teal enums exist only at compile time). Kept in sync with the enum
--- above; `cosmic.sandbox` uses this to reject unknown promises before
--- any enforcement happens.
local PROMISES: {Promise} = {
  "stdio", "rpath", "wpath", "cpath", "dpath", "flock", "fattr", "tty",
  "inet", "unix", "dns", "recvfd", "sendfd", "proc", "exec", "id",
  "unveil", "settime", "prot_exec", "vminfo", "tmppath", "anet", "chown",
}

--- Options for `apply`. `exec` sets the promises children keep after
--- execve. `best_effort` turns an unsupported host into a successful
--- no-op instead of an error — the explicit fail-open escape hatch.
--- `keep_coverage` skips the pre-pledge coverage seal — set it only
--- when the promises still permit the coverage dump at exit.
local record ApplyOptions
  exec: string
  best_effort: boolean
  keep_coverage: boolean
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
  elseif errno.is_code(eno, "ENOSYS") then
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
--- @param opts ApplyOptions? `exec` promises after execve; `best_effort` escape hatch
--- @return boolean True on success
--- @return string? Error message on failure
local function apply(promises: string, opts?: ApplyOptions): boolean, string
  if not available() then
    if opts and opts.best_effort then return true end
    return false, "pledge unsupported on this host"
  end
  seal_coverage(opts and opts.keep_coverage)
  local ok, err = unix.pledge(promises, opts and opts.exec)
  if not ok then
    return false, errno.format(err, "pledge")
  end
  return true
end

local record PledgeModule
  type Promise = Promise
  type ApplyOptions = ApplyOptions
  PROMISES: {Promise}
  apply: function(promises: string, opts?: ApplyOptions): boolean, string
  available: function(): boolean
end

local M: PledgeModule = {
  PROMISES = PROMISES,
  apply = apply,
  available = available,
}

return M
