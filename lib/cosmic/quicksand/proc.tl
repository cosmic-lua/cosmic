--- Process-setup primitives for jail assembly.
---
--- Typed wrappers over cosmo.sandbox.proc for the "after fork, before
--- exec" work of a jailed child plus the PID-1 supervisor loop used
--- by netns + proxy sidecar topologies. Linux-only.
---
--- no_new_privs, drop_privs: call before execve in the jailed child.
--- barrier: synchronize parent/child across unshare + /proc/<pid>/ns/
---   observation windows.
--- become_init: run a PID-1 loop that forwards signals, reaps zombies,
---   and coordinates main-process / sidecar lifecycles.
local cproc = require("cosmo.sandbox.proc")
local Errno = require("cosmic.errno").Errno

local function wrap_err(err: any, fallback: string): string
  if not err then return fallback end
  local e = err as Errno
  if e.doc then return e:doc() end
  return tostring(err)
end

--- One-shot pipe-backed barrier for cross-process fork+unshare
--- synchronization.
local record Barrier
  signal: function(self: Barrier)
  wait: function(self: Barrier)
  drop_read: function(self: Barrier)
  drop_write: function(self: Barrier)
end

--- Options for become_init().
local record InitOpts
  sidecars: {integer}
  signals: {string}
  on_sidecar_exit: function(pid: integer, ws: integer)
end

--- Set PR_SET_NO_NEW_PRIVS on the current process. Irreversible;
--- inherited by children. Required to install seccomp filters
--- without CAP_SYS_ADMIN and to neutralize setuid/setgid/file-caps
--- across execve.
---
--- @return boolean true on success
--- @return string? error message on failure
local function no_new_privs(): boolean, string
  local ok, err = cproc.no_new_privs() as(boolean, any)
  if not ok then return false, wrap_err(err, "no_new_privs failed") end
  return true
end

--- Drop to (uid, gid) and clear capabilities. If uid is nil, no-op.
--- If uid == 0, keep root but still clear caps ("root without
--- superpowers"). gid defaults to uid when nil.
---
--- Performs PR_SET_KEEPCAPS, setresgid, setresuid, capset(0,0,0) in
--- order. On non-Linux hosts where capset is ENOSYS, returns success
--- since there are no Linux caps to clear.
---
--- @param uid integer? target uid (nil = no-op)
--- @param gid integer? target gid (defaults to uid)
--- @return boolean true on success
--- @return string? error message on failure
local function drop_privs(uid: integer, gid: integer): boolean, string
  local ok, err = cproc.drop_privs(uid, gid) as(boolean, any)
  if not ok then return false, wrap_err(err, "drop_privs failed") end
  return true
end

--- Allocate a one-shot pipe-backed barrier. Typical pattern:
---
---     local b = assert(proc.barrier())
---     local pid = assert(unix.fork())
---     if pid == 0 then
---       b:drop_read()
---       -- ... unshare/setup ...
---       b:signal()
---       unix.execvp(cmd[1], cmd)
---     end
---     b:drop_write()
---     b:wait()
---
--- @return Barrier? barrier object on success
--- @return string? error message on failure
local function barrier(): Barrier, string
  local b, err = cproc.barrier() as(Barrier, any)
  if not b then return nil, wrap_err(err, "barrier failed") end
  return b
end

--- Run a PID-1 supervisor loop. Forwards signals in opts.signals
--- (default SIGINT/SIGTERM/SIGHUP) to main_pid, reaps zombies, and
--- when main_pid exits kills + reaps all opts.sidecars. Returns an
--- integer exit code suitable for os.exit():
---
---   0..255         main_pid exited with that status
---   128 + signum   main_pid was terminated by signum
---   1              unexpected supervisor failure, or a sidecar
---                  exited before main_pid
---
--- Not thread-safe: uses process-wide sigaction.
---
--- @param main_pid integer pid of the main user-visible child
--- @param opts InitOpts? sidecar pids, signal set, exit hook
--- @return integer exit code for os.exit()
local function become_init(main_pid: integer, opts: InitOpts): integer
  return cproc.become_init(main_pid, opts as any) as integer
end

local record ProcModule
  no_new_privs: function(): boolean, string
  drop_privs: function(uid: integer, gid: integer): boolean, string
  barrier: function(): Barrier, string
  become_init: function(main_pid: integer, opts: InitOpts): integer
  DEFAULT_SIGNALS: {string}
end

local M: ProcModule = {
  no_new_privs = no_new_privs,
  drop_privs = drop_privs,
  barrier = barrier,
  become_init = become_init,
  DEFAULT_SIGNALS = cproc.DEFAULT_SIGNALS,
}

return M
