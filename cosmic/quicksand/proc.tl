--- Process-setup primitives for box assembly.
---
--- Typed implementation over cosmo.unix for the "after fork, before
--- exec" work of a boxed child plus the PID-1 supervisor loop used
--- by netns + proxy sidecar topologies. Linux-only.
---
--- no_new_privs, drop_privs: call before execve in the boxed child.
--- setup_userns_maps: write uid_map / setgroups / gid_map after
---   unshare(CLONE_NEWUSER) so the child has a valid identity.
--- barrier: synchronize parent/child across unshare + /proc/<pid>/ns/
---   observation windows.
--- fork_pidns: enter a fresh PID namespace and fork its PID 1.
--- become_init: run a PID-1 loop that forwards signals, reaps zombies,
---   and coordinates main-process / sidecar lifecycles.
local unix = require("cosmo.unix")
local errno = require("cosmic.errno")

--- One-shot pipe-backed barrier for cross-process fork+unshare
--- synchronization.
local record Barrier
  signal: function(self: Barrier)
  wait: function(self: Barrier): boolean, string
  drop_read: function(self: Barrier)
  drop_write: function(self: Barrier)
end

--- Options for become_init().
local record InitOptions
  sidecars: {integer}
  signals: {string}
  on_sidecar_exit: function(pid: integer, ws: integer)
end

--- Default signal set forwarded by become_init.
local DEFAULT_SIGNALS: {string} = {"SIGINT", "SIGTERM", "SIGHUP"}

--- Set PR_SET_NO_NEW_PRIVS on the current process. Irreversible;
--- inherited by children. Required to install seccomp filters
--- without CAP_SYS_ADMIN and to neutralize setuid/setgid/file-caps
--- across execve.
---
--- @return boolean true on success
--- @return string? error message on failure
local function no_new_privs(): boolean, string
  local ok, err = unix.prctl(unix.PR_SET_NO_NEW_PRIVS, 1)
  if not ok then return false, errno.str(err, "no_new_privs") end
  return true
end

--- Drop to (uid, gid) and clear capabilities. If uid is nil, no-op.
--- If uid == 0, keep root but still clear caps ("root without
--- superpowers"). gid defaults to uid when nil.
---
--- Performs PR_SET_KEEPCAPS, setresgid, setresuid, capset(0,0,0) in
--- order. PR_SET_KEEPCAPS preserves capabilities across the setuid so
--- they can be cleared explicitly afterwards; all three of real /
--- effective / saved ids are switched so there is no path back. On
--- non-Linux hosts where capset is ENOSYS, returns success since
--- there are no Linux caps to clear.
---
--- @param uid integer? target uid (nil = no-op)
--- @param gid integer? target gid (defaults to uid)
--- @return boolean true on success
--- @return string? error message on failure
local function drop_privs(uid: integer, gid: integer): boolean, string
  if uid == nil then return true end
  if gid == nil then gid = uid end
  if uid ~= 0 then
    local kok, kerr = unix.prctl(unix.PR_SET_KEEPCAPS, 1)
    if not kok then return false, errno.str(kerr, "PR_SET_KEEPCAPS") end
    local gok, gerr = unix.setresgid(gid, gid, gid)
    if not gok then return false, errno.str(gerr, "setresgid") end
    local uok, uerr = unix.setresuid(uid, uid, uid)
    if not uok then return false, errno.str(uerr, "setresuid") end
  end
  local cok, cerr, ceno = unix.capset(0, 0, 0)
  if not cok then
    if errno.is(ceno, "ENOSYS") then return true end
    return false, errno.str(cerr, "capset")
  end
  return true
end

--- Open `path` write-only and write `data` in one shot. On failure
--- returns false plus the binding's error string and numeric errno,
--- so callers can classify the failure (e.g. a benign ENOENT).
local function write_file(path: string, data: string): boolean, string, integer
  local fd, oerr, oeno = unix.open(path, unix.O_WRONLY)
  if not fd then return false, oerr, oeno end
  local n, werr, weno = unix.write(fd, data)
  unix.close(fd)
  if not n then return false, werr, weno end
  return true
end

--- Write uid_map / setgroups / gid_map for the current process so
--- that inner uid 0 maps to the host `uid` (and inner gid 0 to host
--- `gid`). Must be called after unshare(CLONE_NEWUSER) and before any
--- operation that requires a valid identity (setresuid, capset,
--- mount, ...). Equivalent to:
---
---     echo "0 $uid 1" > /proc/self/uid_map
---     echo "deny"     > /proc/self/setgroups   # kernel >= 3.19
---     echo "0 $gid 1" > /proc/self/gid_map
---
--- The setgroups "deny" write must precede the gid_map write on
--- kernels >= 3.19; unprivileged writers are rejected from gid_map
--- otherwise. On kernels without the setgroups proc file the write
--- fails with ENOENT, which is benign and ignored.
---
--- @param uid integer? host uid to map to inner 0 (default: euid)
--- @param gid integer? host gid to map to inner 0 (default: egid)
--- @return boolean true on success
--- @return string? error message on failure
local function setup_userns_maps(uid: integer, gid: integer): boolean, string
  if uid == nil then uid = unix.geteuid() end
  if gid == nil then gid = unix.getegid() end
  local ok, err = write_file("/proc/self/uid_map",
    "0 " .. tostring(uid) .. " 1\n")
  if not ok then return false, errno.str(err, "uid_map write") end
  local sg, sgerr, sgeno = write_file("/proc/self/setgroups", "deny")
  if not sg and not errno.is(sgeno, "ENOENT") then
    return false, errno.str(sgerr, "setgroups write")
  end
  local gok, gerr = write_file("/proc/self/gid_map",
    "0 " .. tostring(gid) .. " 1\n")
  if not gok then return false, errno.str(gerr, "gid_map write") end
  return true
end

--- Allocate a one-shot pipe-backed barrier. After fork, each side
--- drops the end it won't use, then uses the end it kept:
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
--- signal() writes one byte and closes the write end. wait() reads
--- one byte (EOF counts as signaled, which propagates child crashes),
--- retrying internally on EINTR so a forwarded signal can never
--- release the caller before the other side actually signals or
--- exits, and closes the read end. drop_read() / drop_write() are
--- idempotent.
---
--- @return Barrier? barrier object on success
--- @return string? error message on failure
local function barrier(): Barrier | nil, string
  -- On failure pipe returns nil, err (string), errno; the error string
  -- lands in the second slot where the write fd would have been.
  local r, w = unix.pipe()
  if not r then return nil, errno.str(w, "pipe") end
  local rfd: integer = r
  local wfd: integer = w
  local b: Barrier = {}
  b.signal = function(_: Barrier)
    if wfd then
      unix.write(wfd, "x")
      unix.close(wfd)
      wfd = nil
    end
  end
  b.wait = function(_: Barrier): boolean, string
    if not rfd then return true end
    while true do
      -- A byte or EOF both mean "signaled". EINTR (a forwarded
      -- signal arriving mid-read) must be retried, never treated as
      -- EOF -- doing so would release the caller before the other
      -- side actually finished setup, the exact race this barrier
      -- exists to prevent.
      local chunk, rerr, reno = unix.read(rfd, 1)
      if chunk then
        unix.close(rfd)
        rfd = nil
        return true
      end
      if not errno.is(reno, "EINTR") then
        unix.close(rfd)
        rfd = nil
        return false, errno.str(rerr, "barrier wait")
      end
    end
  end
  b.drop_read = function(_: Barrier)
    if rfd then
      unix.close(rfd)
      rfd = nil
    end
  end
  b.drop_write = function(_: Barrier)
    if wfd then
      unix.close(wfd)
      wfd = nil
    end
  end
  return b
end

--- Enter a new PID namespace and fork a child that becomes PID 1
--- inside it. Returns the child's pid to the parent and 0 to the
--- child (mirroring unix.fork), or nil + error on failure.
---
--- unshare(CLONE_NEWPID) does NOT move the calling process into the
--- new namespace — only its future children are born there, and the
--- first such child is PID 1. Only that child can mount a private
--- procfs that shows just the sandbox's own processes; mounting from
--- the parent leaks all host processes. Typical flow: the child
--- mounts /proc then execs the workload, while the parent runs
--- become_init() so the child's exit status is reaped.
---
--- @return integer? child pid in the parent, 0 in the child
--- @return string? error message on failure
local function fork_pidns(): integer | nil, string
  local ok, uerr = unix.unshare(unix.CLONE_NEWPID)
  if not ok then
    return nil, errno.str(uerr, "unshare(CLONE_NEWPID)")
  end
  local pid, ferr = unix.fork()
  if not pid then return nil, errno.str(ferr, "fork") end
  return pid
end

--- Run a PID-1 supervisor loop. Forwards signals in opts.signals
--- (default SIGINT/SIGTERM/SIGHUP) to main_pid, reaps zombies, and
--- when main_pid exits kills + reaps all opts.sidecars. If a sidecar
--- exits first, kills main_pid (after invoking opts.on_sidecar_exit,
--- if set) and returns 1. EINTR during wait is handled internally.
--- Returns an integer exit code suitable for os.exit():
---
---   0..255         main_pid exited with that status
---   128 + signum   main_pid was terminated by signum
---   1              unexpected supervisor failure, or a sidecar
---                  exited before main_pid
---
--- Not thread-safe: uses process-wide sigaction.
---
--- @param main_pid integer pid of the main user-visible child
--- @param opts InitOptions? sidecar pids, signal set, exit hook
--- @return integer exit code for os.exit()
local function become_init(main_pid: integer, opts: InitOptions): integer
  opts = opts or {}
  local sidecars: {integer} = opts.sidecars or {}
  local signals: {string} = opts.signals or DEFAULT_SIGNALS
  local by_name = unix as {string: any} -- cast: constant lookup by name

  for _, s in ipairs(signals) do
    local n = by_name[s] as integer -- cast: from any
    if n then
      unix.sigaction(n, function()
          pcall(unix.kill, main_pid, n)
        end)
    end
  end

  local function kill_and_reap(pid: integer)
    pcall(unix.kill, pid, unix.SIGTERM)
    pcall(unix.wait, pid)
  end

  while true do
    -- On success: pid, wait status, rusage. On failure: nil, err
    -- (string), errno — so `weno` is the numeric errno exactly when
    -- pid is nil.
    local pid, ws, weno = unix.wait()
    if not pid then
      -- EINTR = a forwarded signal arrived mid-wait; loop and reap.
      if not errno.is(weno, "EINTR") then
        return 1
      end
    elseif pid == main_pid then
      for _, s in ipairs(sidecars) do
        kill_and_reap(s)
      end
      if unix.WIFEXITED(ws) then
        return unix.WEXITSTATUS(ws)
      end
      if unix.WIFSIGNALED(ws) then
        return 128 + (unix.WTERMSIG(ws))
      end
      return 1
    else
      -- A sidecar exited before main: kill main and report failure.
      -- Unknown children (spurious reaps) keep the loop waiting.
      for _, s in ipairs(sidecars) do
        if s == pid then
          if opts.on_sidecar_exit then
            pcall(opts.on_sidecar_exit, pid, ws)
          end
          kill_and_reap(main_pid)
          return 1
        end
      end
    end
  end
end

local record ProcModule
  type Barrier = Barrier
  no_new_privs: function(): boolean, string
  drop_privs: function(uid: integer, gid: integer): boolean, string
  setup_userns_maps: function(uid: integer, gid: integer): boolean, string
  barrier: function(): Barrier | nil, string
  fork_pidns: function(): integer | nil, string
  become_init: function(main_pid: integer, opts: InitOptions): integer
  DEFAULT_SIGNALS: {string}
end

local M: ProcModule = {
  no_new_privs = no_new_privs,
  drop_privs = drop_privs,
  setup_userns_maps = setup_userns_maps,
  barrier = barrier,
  fork_pidns = fork_pidns,
  become_init = become_init,
  DEFAULT_SIGNALS = DEFAULT_SIGNALS,
}

return M
