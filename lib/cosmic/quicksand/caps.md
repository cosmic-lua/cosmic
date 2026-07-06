# caps

 Linux capability bounding-set control for box assembly.

 Typed wrapper over cosmo.unix prctl(2) capability operations. The
 companion to cosmic.quicksand.proc: where proc.drop_privs clears the
 *current* capability set (effective/permitted/inheritable via
 capset), this module manipulates the capability *bounding set* — the
 ceiling that limits which capabilities a process (or anything it
 execve's) can ever hold. Dropping a capability from the bounding set
 is irreversible and inherited across fork/exec, so a workload can
 never regain it, even by executing a setuid or file-capability
 binary.

 Intended for the "after fork, before exec" window of a boxed child,
 while it still holds CAP_SETPCAP in its user namespace. Call
 drop_bounding() before proc.drop_privs (which clears CAP_SETPCAP and
 would make subsequent PR_CAPBSET_DROP calls fail with EPERM).

 Linux-only. On non-Linux hosts (or a cosmos build without the CAP_*
 constants) the constants are nil; drop_bounding() is then a
 successful no-op and supported() returns false.

## Types

### DropOpts

 Options for drop_bounding().

```teal
local record DropOpts
  keep: {string}
end
```

### CapsModule

```teal
local record CapsModule
  NAMES: {string}
  supported: function(): boolean
  number_of: function(name: string): integer | nil, string
  mask: function(names: {string}): integer | nil, string
  bounding_read: function(cap: string): boolean | nil, string
  bounding_drop: function(cap: string): boolean, string
  drop_bounding: function(opts?: DropOpts): boolean, string
end
```

## Functions

### number_of

```teal
function number_of(name: string): integer | nil, string
```

 Resolve a capability name (e.g. "CAP_NET_RAW") to its integer number
 for the running host, or nil + error if the name is unknown or the
 host does not define it.

**Parameters:**

- `name` (string) - capability name

**Returns:**

- integer? - capability number
- string? - error message

### supported

```teal
function supported(): boolean
```

 True when the capability bounding-set API is wired up on this host
 (Linux with prctl + the CAP_* / PR_CAPBSET_* constants). A true
 result means the calls exist; actually dropping from the bounding
 set additionally requires CAP_SETPCAP at runtime.

**Returns:**

- boolean - supported

### mask

```teal
function mask(names: {string}): integer | nil, string
```

 Build a capset(2) bitmask from capability names: bit N (1 << number)
 is set for each named capability. Suitable for the effective /
 permitted / inheritable arguments of unix.capset.

**Parameters:**

- `names` ({string}) - capability names

**Returns:**

- integer? - bitmask
- string? - error message if a name is unknown

### bounding_read

```teal
function bounding_read(cap: string): boolean | nil, string
```

 Read whether a capability is present in the current bounding set via
 PR_CAPBSET_READ.

**Parameters:**

- `cap` (string) - capability name

**Returns:**

- boolean? - true if in the bounding set, false if not
- string? - error message on failure

### bounding_drop

```teal
function bounding_drop(cap: string): boolean, string
```

 Remove a single capability from the current bounding set via
 PR_CAPBSET_DROP. Irreversible and inherited across execve. Requires
 CAP_SETPCAP.

**Parameters:**

- `cap` (string) - capability name

**Returns:**

- boolean - true on success
- string? - error message on failure

### drop_bounding

```teal
function drop_bounding(opts?: DropOpts): boolean, string
```

 Drop every capability from the bounding set, optionally retaining
 the names in `opts.keep`. Iterates 0..CAP_LAST_CAP calling
 PR_CAPBSET_DROP. Irreversible and inherited across execve, so a
 workload can never acquire a dropped capability afterwards — not
 even by executing a setuid / file-capability binary.
 Must run while the caller still holds CAP_SETPCAP (e.g. immediately
 after unshare(CLONE_NEWUSER) with a uid map, before proc.drop_privs
 clears the capability set). A cap number the kernel does not know
 (EINVAL) is skipped; ENOSYS ends the sweep successfully. On a host
 without the CAP_* constants (non-Linux) this is a successful no-op.

**Parameters:**

- `opts` (DropOpts?) - optional keep-set

**Returns:**

- boolean - true on success
- string? - error message on failure
