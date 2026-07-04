# netns

 Linux network-namespace primitives.

 Typed implementation over cosmo.unix: namespace fds, setns/unshare,
 and SIOC* interface-flag ioctls for bringing loopback up inside a
 fresh namespace. All calls are Linux-only and return cosmic's
 value,string error shape.

 Typical flow in a forked child that wants to live in its own
 network namespace with only loopback reachable:

     local ns = require("cosmic.quicksand.netns")
     assert(ns.unshare())
     assert(ns.bring_up("lo"))

 To enter an existing child's namespace from the parent:

     local fd = assert(ns.open(child_pid))
     assert(ns.enter(fd))
     ns.close(fd)

## Types

### NetnsModule

```teal
local record NetnsModule
  open: function(pid: integer): integer, string
  enter: function(fd: integer): boolean, string
  unshare_user: function(): boolean, string
  unshare: function(): boolean, string
  bring_up: function(name: string): boolean, string
  bring_down: function(name: string): boolean, string
  get_flags: function(name: string): integer, string
  set_flags: function(name: string, flags: integer): boolean, string
  close: function(fd: integer): boolean, string
end
```

## Functions

### get_flags

```teal
function get_flags(name: string): integer, string
```

 Read the current IFF_* flags on `name` in the current net namespace.

**Parameters:**

- `name` (string) - interface name (e.g. "lo")

**Returns:**

- integer? - flags bitmask on success
- string? - error message on failure

### set_flags

```teal
function set_flags(name: string, flags: integer): boolean, string
```

 Set the IFF_* flags on `name` in the current net namespace.

**Parameters:**

- `name` (string) - interface name
- `flags` (integer) - IFF_* bitmask to write

**Returns:**

- boolean - true on success
- string? - error message on failure

### open

```teal
function open(pid: integer): integer, string
```

 Open the network namespace of `pid` as a file descriptor.
 Pass nil (or omit) to open the current process's net namespace.
 Caller owns the fd and must close() it when done.
 O_CLOEXEC: a namespace fd that leaks across exec into a sandboxed
 child hands it a setns(2) handle back to the parent namespace — a
 direct sandbox escape.

**Parameters:**

- `pid` (integer?) - target pid, or nil for self

**Returns:**

- integer? - fd on success
- string? - error message on failure

### enter

```teal
function enter(fd: integer): boolean, string
```

 Join the net namespace represented by `fd` (e.g. from open()).
 Irreversible for the current thread; fork first if you need to
 return to the prior namespace.

**Parameters:**

- `fd` (integer) - file descriptor for a /proc/<pid>/ns/net handle

**Returns:**

- boolean - true on success
- string? - error message on failure

### unshare_user

```teal
function unshare_user(): boolean, string
```

 Create and enter a new user namespace in the current thread.
 Equivalent to `unshare(CLONE_NEWUSER)`; grants the thread the
 capabilities needed to unshare a network namespace unprivileged.
 unshare is irreversible for the calling thread, so run it in a
 subprocess when the original namespace must be preserved.

**Returns:**

- boolean - true on success
- string? - error message on failure

### unshare

```teal
function unshare(): boolean, string
```

 Create and enter a new network namespace in the current thread.
 Equivalent to `unshare(CLONE_NEWNET)`; requires either root or
 unshare_user() beforehand.

**Returns:**

- boolean - true on success
- string? - error message on failure

### bring_up

```teal
function bring_up(name: string): boolean, string
```

 Bring `name` up in the current net namespace (reads flags, sets
 IFF_UP, writes them back). Idempotent.

**Parameters:**

- `name` (string) - interface name (e.g. "lo")

**Returns:**

- boolean - true on success
- string? - error message on failure

### bring_down

```teal
function bring_down(name: string): boolean, string
```

 Bring `name` down in the current net namespace. Idempotent.

**Parameters:**

- `name` (string) - interface name

**Returns:**

- boolean - true on success
- string? - error message on failure

### close

```teal
function close(fd: integer): boolean, string
```

 Close a file descriptor previously returned by open().

**Parameters:**

- `fd` (integer) - file descriptor

**Returns:**

- boolean - true on success
- string? - error message on failure
