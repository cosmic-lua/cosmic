# proc

 Process-setup primitives for jail assembly.

 Typed wrappers over cosmo.sandbox.proc for the "after fork, before
 exec" work of a jailed child plus the PID-1 supervisor loop used
 by netns + proxy sidecar topologies. Linux-only.

 no_new_privs, drop_privs: call before execve in the jailed child.
 barrier: synchronize parent/child across unshare + /proc/<pid>/ns/
   observation windows.
 become_init: run a PID-1 loop that forwards signals, reaps zombies,
   and coordinates main-process / sidecar lifecycles.

## Types

### Barrier

 One-shot pipe-backed barrier for cross-process fork+unshare
 synchronization.

```teal
local record Barrier
  signal: function(self: Barrier)
  wait: function(self: Barrier)
  drop_read: function(self: Barrier)
  drop_write: function(self: Barrier)
end
```

### InitOpts

 Options for become_init().

```teal
local record InitOpts
  sidecars: {integer}
  signals: {string}
  on_sidecar_exit: function(pid: integer, ws: integer)
end
```

### ProcModule

```teal
local record ProcModule
  no_new_privs: function(): boolean, string
  drop_privs: function(uid: integer, gid: integer): boolean, string
  barrier: function(): Barrier, string
  become_init: function(main_pid: integer, opts: InitOpts): integer
  DEFAULT_SIGNALS: {string}
end
```

## Functions

### no_new_privs

```teal
function no_new_privs(): boolean, string
```

 Set PR_SET_NO_NEW_PRIVS on the current process. Irreversible;
 inherited by children. Required to install seccomp filters
 without CAP_SYS_ADMIN and to neutralize setuid/setgid/file-caps
 across execve.

**Returns:**

- boolean - true on success
- string? - error message on failure

### drop_privs

```teal
function drop_privs(uid: integer, gid: integer): boolean, string
```

 Drop to (uid, gid) and clear capabilities. If uid is nil, no-op.
 If uid == 0, keep root but still clear caps ("root without
 superpowers"). gid defaults to uid when nil.
 Performs PR_SET_KEEPCAPS, setresgid, setresuid, capset(0,0,0) in
 order. On non-Linux hosts where capset is ENOSYS, returns success
 since there are no Linux caps to clear.

**Parameters:**

- `uid` (integer?) - target uid (nil = no-op)
- `gid` (integer?) - target gid (defaults to uid)

**Returns:**

- boolean - true on success
- string? - error message on failure

### barrier

```teal
function barrier(): Barrier, string
```

 Allocate a one-shot pipe-backed barrier. Typical pattern:
     local b = assert(proc.barrier())
     local pid = assert(unix.fork())
     if pid == 0 then
       b:drop_read()
       -- ... unshare/setup ...
       b:signal()
       unix.execvp(cmd[1], cmd)
     end
     b:drop_write()
     b:wait()

**Returns:**

- Barrier? - barrier object on success
- string? - error message on failure

### become_init

```teal
function become_init(main_pid: integer, opts: InitOpts): integer
```

 Run a PID-1 supervisor loop. Forwards signals in opts.signals
 (default SIGINT/SIGTERM/SIGHUP) to main_pid, reaps zombies, and
 when main_pid exits kills + reaps all opts.sidecars. Returns an
 integer exit code suitable for os.exit():
   0..255         main_pid exited with that status
   128 + signum   main_pid was terminated by signum
   1              unexpected supervisor failure, or a sidecar
                  exited before main_pid
 Not thread-safe: uses process-wide sigaction.

**Parameters:**

- `main_pid` (integer) - pid of the main user-visible child
- `opts` (InitOpts?) - sidecar pids, signal set, exit hook

**Returns:**

- integer - exit code for os.exit()
