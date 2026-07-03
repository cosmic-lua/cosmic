--- cosmo.sandbox.proc: process-setup helpers.
---
--- Composable pieces for the "after fork, before exec" portion of a
--- jailed child, plus the PID-1 supervisor loop used by the netns-proxy
--- and claude-code examples. All helpers return `nil, unix.Errno` on
--- failure, matching the rest of the cosmo.sandbox.* library.
---
--- Linux-only.

local unix = require "unix"

local M = {}

--- proc.no_new_privs() → true | nil, unix.Errno
---
--- Set PR_SET_NO_NEW_PRIVS on the current process. Once set:
---   * execve() no longer grants setuid/setgid/file-cap privileges,
---   * the bit is inherited by all children (and cannot be cleared),
---   * seccomp filters can be installed without CAP_SYS_ADMIN.
---
--- Call this before pivot_root / execve in any jail that doesn't
--- explicitly need privilege escalation.
function M.no_new_privs()
  local ok, err = unix.prctl(unix.PR_SET_NO_NEW_PRIVS, 1)
  if not ok then return nil, err end
  return true
end

--- proc.drop_privs(uid, gid) → true | nil, unix.Errno
---
--- Drop to (uid, gid) and clear capabilities. Full dance:
---
---   1. PR_SET_KEEPCAPS — preserve capabilities across setuid, so we
---      can explicitly clear them after switching uid. Without this,
---      the kernel drops caps silently on setuid(non-zero) and we'd
---      have no chance to inspect what was kept.
---   2. setresgid(gid, gid, gid)
---   3. setresuid(uid, uid, uid) — all three (real/effective/saved)
---      so there's no path back.
---   4. capset(0, 0, 0) — clear the effective, permitted, and
---      inheritable capability sets.
---
--- Argument semantics:
---   uid == nil   no-op. Caller explicitly does not want to change uid
---                or clear capabilities.
---   uid == 0     don't setuid (we're staying root) but still clear
---                capabilities — "root without superpowers".
---   uid > 0      full drop: switch to uid, switch gid (defaults to uid
---                when gid is nil), clear caps.
---
--- Returns true on success or when uid is nil. Returns nil,Errno on
--- syscall failure at any step.
function M.drop_privs(uid, gid)
  if uid == nil then return true end
  gid = gid or uid
  if uid ~= 0 then
    local ok, err = unix.prctl(unix.PR_SET_KEEPCAPS, 1)
    if not ok then return nil, err end
    ok, err = unix.setresgid(gid, gid, gid)
    if not ok then return nil, err end
    ok, err = unix.setresuid(uid, uid, uid)
    if not ok then return nil, err end
  end
  local ok, err = unix.capset(0, 0, 0)
  if not ok then
    -- On non-Linux hosts capset is ENOSYS; there are no Linux caps to
    -- clear, so treat that as success. Any other errno is real.
    if err and err:errno() == unix.ENOSYS then return true end
    return nil, err
  end
  return true
end

--- proc.setup_userns_maps(uid, gid) → true | nil, unix.Errno
---
--- Write uid_map / setgroups / gid_map for the current process so that
--- inner uid 0 maps to the host `uid` (and inner gid 0 to host `gid`).
--- Must be called after `unshare(CLONE_NEWUSER)` and before any
--- operation that requires a valid identity (setresuid, capset, mount,
--- etc). Equivalent to the canonical three-step incantation:
---
---     echo "0 $uid 1" > /proc/self/uid_map
---     echo "deny"     > /proc/self/setgroups   # kernel ≥ 3.19
---     echo "0 $gid 1" > /proc/self/gid_map
---
--- The setgroups "deny" write must come before the gid_map write on
--- kernels ≥3.19; an unprivileged writer is rejected from gid_map
--- otherwise. On kernels old enough not to expose setgroups as a
--- proc file the write fails with ENOENT, which is benign and
--- silently ignored.
---
--- Arguments default to the current euid/egid, matching the common
--- "map my host identity to root inside the new user ns" case.
local function write_all(path, data)
  local fd, err = unix.open(path, unix.O_WRONLY)
  if not fd then return nil, err end
  local ok, werr = unix.write(fd, data)
  unix.close(fd)
  if not ok then return nil, werr end
  return true
end

function M.setup_userns_maps(uid, gid)
  uid = uid or unix.geteuid()
  gid = gid or unix.getegid()
  local ok, err = write_all("/proc/self/uid_map", "0 "..uid.." 1\n")
  if not ok then return nil, err end
  local sg, sgerr = write_all("/proc/self/setgroups", "deny")
  if not sg and sgerr and sgerr:errno() ~= unix.ENOENT then
    return nil, sgerr
  end
  return write_all("/proc/self/gid_map", "0 "..gid.." 1\n")
end

--- proc.barrier() → {signal, wait, drop_read, drop_write} | nil, err
---
--- Cross-process synchronization primitive: a one-shot pipe-based
--- barrier. The common use case is closing the fork + unshare race in
--- examples: a parent that forks a child and wants to observe the
--- child's namespace fd in /proc must wait for the child to finish
--- `unshare()` before opening `/proc/<pid>/ns/<kind>` — otherwise the
--- fd may point at the parent's namespace.
---
--- After fork, each side drops the end it won't use, then uses the
--- end it kept:
---
---     local b = assert(proc.barrier())
---     local pid = assert(unix.fork())
---     if pid == 0 then
---       b:drop_read()                 -- child will signal, never wait
---       assert(unix.unshare(flags))
---       b:signal()                    -- tell parent "I've unshared"
---       unix.execvp(cmd[1], cmd)
---     end
---     b:drop_write()                  -- parent will wait, never signal
---     b:wait()                        -- blocks until child signal
---     local nsfd = assert(netns.open(pid))   -- safe: child has unshared
---
--- `signal()` writes one byte and closes the write end. `wait()`
--- reads one byte from the read end (EOF counts as signaled, which
--- propagates child crashes) and closes the read end. `drop_read()`
--- / `drop_write()` are idempotent.
local Barrier = {__name = "cosmo.sandbox.proc.Barrier"}
Barrier.__index = Barrier

function Barrier:signal()
  if self._w then unix.write(self._w, "x"); unix.close(self._w); self._w = nil end
end
function Barrier:wait()
  if self._r then unix.read(self._r, 1); unix.close(self._r); self._r = nil end
end
function Barrier:drop_read()
  if self._r then unix.close(self._r); self._r = nil end
end
function Barrier:drop_write()
  if self._w then unix.close(self._w); self._w = nil end
end

function M.barrier()
  local r, w, err = unix.pipe()
  if not r then return nil, w or err end
  return setmetatable({_r = r, _w = w}, Barrier)
end

--- proc.fork_pidns() → child_pid | nil, err
---
--- Enter a new PID namespace and fork a child that becomes PID 1
--- inside it. Returns the child PID to the caller (the parent); the
--- child runs `child_fn()` (if given) and then exits with unix.exit(0).
--- If `child_fn` is omitted, only the fork+unshare mechanics are
--- performed — the child returns nil (indicating "I am the child") and
--- is expected to exec or call unix.exit() itself.
---
--- Why fork is required: `unshare(CLONE_NEWPID)` does NOT move the
--- calling process into the new PID namespace — it only causes the
--- process's FUTURE CHILDREN to be born into it.  The first such child
--- is PID 1 of the new namespace.  Only that child (PID 1 of the new
--- pidns) can mount a fresh procfs that shows only the sandbox's own
--- processes.  Attempting to mount procfs from the parent (which remains
--- in the outer pidns) produces a procfs that leaks all host processes.
---
--- Typical usage in a jail-setup child (already in CLONE_NEWNS):
---
---     -- Step 1: enter new PID namespace and fork the grandchild.
---     local child_pid, err = proc.fork_pidns()
---     if child_pid == nil then
---       -- We are the grandchild (PID 1 in the new pidns).
---       -- Mount private /proc, then exec the jailed command.
---       assert(fs.proc())
---       local _, e = unix.execvp(cmd[1], cmd)
---       unix.exit(127)
---     end
---     -- We are the wrapper child (parent of grandchild).
---     -- Run a minimal PID-1 supervisor loop so the grandchild's
---     -- exit status is properly reaped (PID 1 must reap all zombies).
---     os.exit(proc.become_init(child_pid))
---
--- Returns:
---   parent side: child_pid (integer > 0), or nil, err on unshare/fork failure.
---   child side:  nil (i.e. child_pid == false/nil from unix.fork check)
---     — but NOTE: the child never returns from fork_pidns in the normal
---     flow above because it immediately execs or calls unix.exit().
---
--- Security note: the parent (wrapper child) remains in the OUTER PID
--- namespace, but because it is inside CLONE_NEWNS it cannot re-enter
--- the outer procfs.  The child (grandchild) is the only process that
--- mounts and uses the private procfs.
function M.fork_pidns()
  -- Calling unshare(CLONE_NEWPID) here makes the *next* fork's child
  -- land in a fresh PID namespace as PID 1.
  local ok, err = unix.unshare(unix.CLONE_NEWPID)
  if not ok then return nil, err end

  local child_pid, ferr = unix.fork()
  if not child_pid then return nil, ferr end

  -- child_pid == 0: we are the grandchild, PID 1 of the new pidns.
  -- Return nil so the caller can distinguish child from parent.
  if child_pid == 0 then
    return nil
  end

  -- child_pid > 0: we are the parent.  Return the child's PID.
  return child_pid
end

--- Default signal set forwarded by become_init.
M.DEFAULT_SIGNALS = { "SIGINT", "SIGTERM", "SIGHUP" }

--- proc.become_init(main_pid, opts) → exit_code
---
--- Run a PID-1-style supervisor loop:
---   * forward signals in opts.signals (default: SIGINT/SIGTERM/SIGHUP)
---     to `main_pid` — the user-visible child,
---   * reap zombies with unix.wait() in a loop,
---   * when `main_pid` exits, kill each pid in opts.sidecars and reap
---     them, then return main_pid's exit status,
---   * if any sidecar pid exits unexpectedly first, kill main_pid and
---     return 1.
---
--- EINTR during wait() is handled internally.
---
--- The installed signal handler runs a Lua closure that pcalls
--- `unix.kill`. This is intentionally simple: the process is expected
--- to be in the supervisor loop (blocked in `unix.wait()`) when a
--- signal arrives, so handler execution is serialized against the
--- main loop by the kernel's standard "signal delivered between
--- syscalls" semantics. Do NOT call this from inside a threaded
--- program — lunix's sigaction is process-wide.
---
--- Returns an integer exit code suitable for `os.exit()`:
---   * 0..255         main_pid exited with that status
---   * 128 + signum   main_pid was terminated by signum
---   * 1              unexpected supervisor failure
---
--- opts:
---   sidecars   {pid, ...}   processes to kill+reap when main exits
---   signals    {string|int} signal names/numbers to forward
---   on_sidecar_exit  callable(pid, ws)  — hook for logging
function M.become_init(main_pid, opts)
  opts = opts or {}
  local sidecars = opts.sidecars or {}
  local signals = opts.signals or M.DEFAULT_SIGNALS
  local on_sidecar_exit = opts.on_sidecar_exit

  local function signum(s)
    if type(s) == "number" then return s end
    return unix[s]
  end

  -- Forward our interrupt/terminate signals to the main child.
  local function forward(sig)
    pcall(unix.kill, main_pid, sig)
  end
  for _, s in ipairs(signals) do
    local n = signum(s)
    if n then
      unix.sigaction(n, function() forward(n) end)
    end
  end

  local function kill_and_reap(pid)
    pcall(unix.kill, pid, unix.SIGTERM)
    pcall(unix.wait, pid)
  end

  while true do
    local pid, ws = unix.wait()
    if not pid then
      -- ws is a unix.Errno on failure. EINTR = a forwarded signal
      -- arrived mid-wait; loop and reap.
      if ws and ws:errno() == unix.EINTR then
        -- continue
      else
        return 1
      end
    elseif pid == main_pid then
      for _, s in ipairs(sidecars) do kill_and_reap(s) end
      if unix.WIFEXITED(ws) then
        return unix.WEXITSTATUS(ws)
      elseif unix.WIFSIGNALED(ws) then
        return 128 + unix.WTERMSIG(ws)
      else
        return 1
      end
    else
      -- A sidecar exited. Kill the main child and return non-zero.
      for _, s in ipairs(sidecars) do
        if s == pid then
          if on_sidecar_exit then
            pcall(on_sidecar_exit, pid, ws)
          end
          kill_and_reap(main_pid)
          return 1
        end
      end
      -- Unknown child (spurious reap); keep waiting.
    end
  end
end

return M
