# pledge

 Restrict the system calls available to the current process.

 Pledging is irreversible: once applied, most system calls become
 unavailable. On Linux, disallowed calls return EPERM; on OpenBSD the
 kernel terminates the process. Use pledge in conjunction with
 `cosmic.unveil` to also narrow filesystem visibility.

 The API is fail-closed: on hosts where the libc cannot enforce a
 pledge (anything other than Linux or OpenBSD), `apply` returns
 `false, "pledge unsupported on this host"` instead of reporting a
 sandbox that does not exist. Callers that want fail-open behavior
 opt in explicitly with `best_effort = true`, or branch on
 `available()` themselves.

 Common promise groups:

   stdio     standard I/O (read, write, close)
   rpath     read-only path operations
   wpath     write operations on paths
   cpath     create and remove paths
   flock     file locking
   tty       terminal operations (isatty, tiocgwinsz, etc.)
   inet      IPv4 / IPv6 sockets
   unix      UNIX-domain sockets
   proc      fork, vfork, kill, wait, etc.
   exec      execve
   unveil    permit subsequent unveil calls

## Types

### ApplyOptions

 Options for `apply`. `exec` sets the promises children keep after
 execve. `best_effort` turns an unsupported host into a successful
 no-op instead of an error — the explicit fail-open escape hatch.

```teal
local record ApplyOptions
  exec: string
  best_effort: boolean
end
```

### PledgeModule

```teal
local record PledgeModule
  PROMISES: {Promise}
  apply: function(promises: string, opts?: ApplyOptions): boolean, string
  available: function(): boolean
end
```

## Functions

### available

```teal
function available(): boolean
```

 True when pledge(2) is actually enforceable on this host (Linux via
 seccomp, OpenBSD natively). Probed once with a no-op
 `unix.pledge(nil, nil)` call — the libc fails that probe closed with
 ENOSYS where enforcement is impossible — and cached. A non-ENOSYS
 failure (e.g. EPERM from an outer filter) still proves the syscall
 is wired up.

**Returns:**

- boolean - True when a pledge can be enforced

### apply

```teal
function apply(promises: string, opts?: ApplyOptions): boolean, string
```

 Apply a pledge to the current process.
 The call is irreversible; subsequent invocations may only narrow the
 set of permitted promises. Fail-closed: on a host where pledge
 cannot be enforced this returns `false, "pledge unsupported on this
 host"` rather than succeeding without a sandbox; pass
 `best_effort = true` to treat that case as a successful no-op.

**Parameters:**

- `promises` (string) - Space-separated promise groups for this process
- `opts` (ApplyOptions?) - `exec` promises after execve; `best_effort` escape hatch

**Returns:**

- boolean - True on success
- string? - Error message on failure
