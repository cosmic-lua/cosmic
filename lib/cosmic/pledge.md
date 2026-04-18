# pledge

 Restrict the system calls available to the current process.

 Pledging is irreversible: once applied, most system calls become
 unavailable. On Linux, disallowed calls return EPERM; on OpenBSD the
 kernel terminates the process. Use pledge in conjunction with
 `cosmic.unveil` to also narrow filesystem visibility.

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

### PledgeModule

```teal
local record PledgeModule
  apply: function(promises: string, execpromises: string, mode: number): boolean, string
end
```

## Functions

### apply

```teal
function apply(promises: string, execpromises: string, mode: number): boolean, string
```

 Apply a pledge to the current process.
 The call is irreversible; subsequent invocations may only narrow the
 set of permitted promises. Passing nil leaves that tier unrestricted.

**Parameters:**

- `promises` (string|nil) - Space-separated promise groups for this process
- `execpromises` (string|nil) - Promises for child processes after exec
- `mode` (number|nil) - Optional mode flags

**Returns:**

- boolean - True on success
- string? - Error message on failure
