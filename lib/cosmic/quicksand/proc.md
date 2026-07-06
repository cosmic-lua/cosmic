# proc

 Process-setup primitives for box assembly.

 Typed implementation over cosmo.unix for the "after fork, before
 exec" work of a boxed child plus the PID-1 supervisor loop used
 by netns + proxy sidecar topologies. Linux-only.

 no_new_privs, drop_privs: call before execve in the boxed child.
 setup_userns_maps: write uid_map / setgroups / gid_map after
   unshare(CLONE_NEWUSER) so the child has a valid identity.
 barrier: synchronize parent/child across unshare + /proc/<pid>/ns/
   observation windows.
 fork_pidns: enter a fresh PID namespace and fork its PID 1.
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
  setup_userns_maps: function(uid: integer, gid: integer): boolean, string
  barrier: function(): Barrier | nil, string
  fork_pidns: function(): integer | nil, string
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
 order. PR_SET_KEEPCAPS preserves capabilities across the setuid so
 they can be cleared explicitly afterwards; all three of real /
 effective / saved ids are switched so there is no path back. On
 non-Linux hosts where capset is ENOSYS, returns success since
 there are no Linux caps to clear.

**Parameters:**

- `uid` (integer?) - target uid (nil = no-op)
- `gid` (integer?) - target gid (defaults to uid)

**Returns:**

- boolean - true on success
- string? - error message on failure

### setup_userns_maps

```teal
function setup_userns_maps(uid: integer, gid: integer): boolean, string
```

 Write uid_map / setgroups / gid_map for the current process so
 that inner uid 0 maps to the host `uid` (and inner gid 0 to host
 `gid`). Must be called after unshare(CLONE_NEWUSER) and before any
 operation that requires a valid identity (setresuid, capset,
 mount, ...). Equivalent to:
     echo "0 $uid 1" > /proc/self/uid_map
     echo "deny"     > /proc/self/setgroups   # kernel >= 3.19
     echo "0 $gid 1" > /proc/self/gid_map
 The setgroups "deny" write must precede the gid_map write on
 kernels >= 3.19; unprivileged writers are rejected from gid_map
 otherwise. On kernels without the setgroups proc file the write
 fails with ENOENT, which is benign and ignored.

**Parameters:**

- `uid` (integer?) - host uid to map to inner 0 (default: euid)
- `gid` (integer?) - host gid to map to inner 0 (default: egid)

**Returns:**

- boolean - true on success
- string? - error message on failure

### barrier

```teal
function barrier(): Barrier | nil, string
```

 Allocate a one-shot pipe-backed barrier. After fork, each side
 drops the end it won't use, then uses the end it kept:
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
 signal() writes one byte and closes the write end. wait() reads
 one byte (EOF counts as signaled, which propagates child crashes)
 and closes the read end. drop_read() / drop_write() are
 idempotent.

**Returns:**

- Barrier? - barrier object on success
- string? - error message on failure

### fork_pidns

```teal
function fork_pidns(): integer | nil, string
```

 Enter a new PID namespace and fork a child that becomes PID 1
 inside it. Returns the child's pid to the parent and 0 to the
 child (mirroring unix.fork), or nil + error on failure.
 unshare(CLONE_NEWPID) does NOT move the calling process into the
 new namespace — only its future children are born there, and the
 first such child is PID 1. Only that child can mount a private
 procfs that shows just the sandbox's own processes; mounting from
 the parent leaks all host processes. Typical flow: the child
 mounts /proc then execs the workload, while the parent runs
 become_init() so the child's exit status is reaped.

**Returns:**

- integer? - child pid in the parent, 0 in the child
- string? - error message on failure

### become_init

```teal
function become_init(main_pid: integer, opts: InitOpts): integer
```

 Run a PID-1 supervisor loop. Forwards signals in opts.signals
 (default SIGINT/SIGTERM/SIGHUP) to main_pid, reaps zombies, and
 when main_pid exits kills + reaps all opts.sidecars. If a sidecar
 exits first, kills main_pid (after invoking opts.on_sidecar_exit,
 if set) and returns 1. EINTR during wait is handled internally.
 Returns an integer exit code suitable for os.exit():
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
