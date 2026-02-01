# sandbox

 Security sandboxing utilities.
 Wraps cosmo.unix for pledge and unveil operations to restrict system calls and filesystem access.

## Types

### Errno

```teal
local record Errno
  errno: function(self: Errno): number
  winerr: function(self: Errno): number
  name: function(self: Errno): string
  call: function(self: Errno): string
  doc: function(self: Errno): string
end
```

### SandboxModule

```teal
local record SandboxModule
  pledge: function(promises?: string, execpromises?: string, mode?: number): boolean, string
  unveil: function(path: string, permissions: string): boolean, string
end
```

## Functions

### pledge

```teal
function pledge(promises?: string, execpromises?: string, mode?: number): boolean, string
```

 Restricts system calls available to the process.
 Pledging causes most system calls to become unavailable. Using pledge is irreversible.
 On Linux disabled calls return EPERM; OpenBSD kills the process.
 Common promise groups include:
 - "stdio": Standard I/O operations (read, write, close, etc.)
 - "rpath": Read-only path operations
 - "wpath": Write operations on paths
 - "cpath": Create/remove paths
 - "flock": File locking operations
 - "tty": Terminal operations (isatty, tiocgwinsz, etc.)
 - "inet": IPv4/IPv6 socket operations
 - "unix": UNIX domain sockets
 - "proc": fork, vfork, kill, wait, etc.
 - "exec": execve operations
 - "unveil": Allow unveil() calls

**Parameters:**

- `promises` (string|nil) - Space-separated promise groups (nil = unrestricted)
- `execpromises` (string|nil) - Promises for child processes after exec (nil = unrestricted)
- `mode` (number|nil) - Optional mode flags

**Returns:**

- boolean - True on success
- string? - Error message on failure

### unveil

```teal
function unveil(path: string, permissions: string): boolean, string
```

 Restricts filesystem visibility to specified paths.
 Once you start using unveil, the entire filesystem is hidden.
 You then specify which paths should become visible by repeatedly calling unveil.
 When finished, call unveil(nil, nil) to commit and lock the policy.
 Permissions:
 - "r": Read-only path operations (corresponds to pledge "rpath")
 - "w": Write operations (corresponds to pledge "wpath")
 - "x": Execute operations (corresponds to pledge "exec"/"execnative")
 - "c": Create and remove paths (corresponds to pledge "cpath")

**Parameters:**

- `path` (string|nil) - Path to unveil (nil to commit policy)
- `permissions` (string|nil) - Permission string like "r", "rw", "rwxc" (nil to commit)

**Returns:**

- boolean - True on success
- string? - Error message on failure
