--- Restrict the system calls available to the current process.
---
--- Pledging is irreversible: once applied, most system calls become
--- unavailable. On Linux, disallowed calls return EPERM; on OpenBSD the
--- kernel terminates the process. Use pledge in conjunction with
--- `cosmic.unveil` to also narrow filesystem visibility.
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
local errstr = require("cosmic.errno").str

--- Apply a pledge to the current process.
---
--- The call is irreversible; subsequent invocations may only narrow the
--- set of permitted promises. Passing nil leaves that tier unrestricted.
---
--- @param promises string|nil Space-separated promise groups for this process
--- @param execpromises string|nil Promises for child processes after exec
--- @param mode number|nil Optional mode flags
--- @return boolean True on success
--- @return string? Error message on failure
local function apply(promises: string, execpromises: string, mode: number): boolean, string
  local ok, err = unix.pledge(promises, execpromises, mode)
  if not ok then
    return false, errstr(err, "pledge")
  end
  return true
end

local record PledgeModule
  apply: function(promises: string, execpromises: string, mode: number): boolean, string
end

local M: PledgeModule = {
  apply = apply,
}

return M
