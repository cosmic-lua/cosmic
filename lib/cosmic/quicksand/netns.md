# netns

 Linux network-namespace primitives.

 Thin typed wrappers over cosmo.sandbox.netns plus the pieces of
 cosmo.unix needed to join a netns without pulling in the full
 lunix namespace. All calls are Linux-only and return cosmic's
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
  unshare: function(): boolean, string
  bring_up: function(name: string): boolean, string
  bring_down: function(name: string): boolean, string
  close: function(fd: integer): boolean, string
end
```

## Functions

### open

```teal
function open(pid: integer): integer, string
```

 Open the network namespace of `pid` as a file descriptor.
 Pass nil (or omit) to open the current process's net namespace.
 Caller owns the fd and must close() it when done.

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

### unshare

```teal
function unshare(): boolean, string
```

 Create and enter a new network namespace in the current thread.
 Equivalent to `unshare(CLONE_NEWNET)`; requires either root or
 CLONE_NEWUSER beforehand.

**Returns:**

- boolean - true on success
- string? - error message on failure

### bring_up

```teal
function bring_up(name: string): boolean, string
```

 Bring `name` up in the current net namespace. Idempotent.

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
