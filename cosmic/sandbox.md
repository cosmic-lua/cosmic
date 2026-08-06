# sandbox

 One-call, fail-closed sandbox facade over unveil, landlock, and
 pledge.

 cosmic ships three mechanism-level sandbox modules with overlapping
 stories: `cosmic.landlock` (Linux), `cosmic.unveil` (OpenBSD, or
 Linux where the libc backs it with landlock), and `cosmic.pledge`
 (Linux, OpenBSD). This module is the one to reach for unless you
 need mechanism-specific control: it takes a single declarative
 policy, picks the right mechanism per OS, and applies the sections
 in the only order that works (fs before sys — a pledged process may
 no longer be allowed to install a filesystem sandbox).

     local sandbox = require("cosmic.sandbox")
     assert(sandbox.apply{
       fs = { exec = { "/usr" }, ro = { "/etc" }, rw = { "/tmp" } },
       sys = { promises = "stdio rpath wpath" },
     })

 Like the mechanism modules, the facade is fail-closed: a section
 that cannot be enforced on this host makes `apply` return
 `nil, "sandbox: ... unsupported on this host"` before anything is
 applied, unless `best_effort = true` opts into skipping unenforceable
 sections — in which case the returned Availability record reports
 which sections actually enforced. `available()` reports what this
 host can enforce.

 Applying is irreversible and process-wide; policies can only be
 narrowed by further calls. `cosmic.quicksand.Box` consumes the same
 `fs` schema for its boxed workloads.

## Types

### Fs

 Filesystem policy: path allowlists. Everything not listed is denied
 once the policy applies. The three groups mean three things: `ro`
 paths are readable and nothing else — a directory of untrusted
 input stays non-executable; `exec` paths are readable *and*
 executable, for binaries and libraries that must run; `rw` paths
 are readable and writable, including creating and removing entries,
 but never executable. A path listed in several groups gets the
 union of their access. A present-but-empty group is a real policy
 (`fs = { ro = {} }` denies everything); a policy with no group at
 all is rejected — omit `fs` entirely to skip filesystem policy.

```teal
local record Fs
  ro: {string}
  rw: {string}
  exec: {string}
end
```

### Sys

 System-call policy: pledge promise groups as a space-separated
 string (see cosmic.pledge for the group list; the `Promise` enum
 there names every valid token). `exec` optionally sets the promises
 children keep after execve.

```teal
local record Sys
  promises: string
  exec: string
end
```

### Policy

 A full sandbox policy. Each section is optional but at least one
 must be present. `best_effort = true` skips sections this host
 cannot enforce instead of failing closed.

```teal
local record Policy
  fs: Fs
  sys: Sys
  best_effort: boolean
  --  The caller asserts this policy still permits the line-coverage
  --  dump, because `fs` grants that directory. Without it the
  --  mechanism seals coverage before restricting — the safe answer
  --  when nobody knows — and the process reports only what it did
  --  before the sandbox landed.
  keep_coverage: boolean
end
```

### Availability

 Per-section enforcement report: `fs` (landlock on Linux, unveil on
 OpenBSD) and `sys` (pledge). `available()` returns what this host
 *can* enforce; a successful `apply` returns what it *did* enforce,
 so a `best_effort` caller can see exactly which sections were
 skipped instead of flying blind.

```teal
local record Availability
  fs: boolean
  sys: boolean
end
```

### SandboxModule

```teal
local record SandboxModule
  apply: function(policy: Policy): Availability | nil, string
  available: function(): Availability
  validate: function(policy: Policy): boolean, string
  plan_landlock: function(fs: Fs, keep_coverage?: boolean): RestrictOptions
end
```

### Rule

alias of `cosmic.landlock.Rule` — field and method table: `cosmic --docs cosmic.landlock.Rule`

### RestrictOptions

alias of `cosmic.landlock.RestrictOptions` — field and method table: `cosmic --docs cosmic.landlock.RestrictOptions`

## Functions

### available

```teal
function available(): Availability
```

 Report what this host can enforce. Sections requested in `apply`
 beyond this fail closed (or are skipped under `best_effort`).

**Returns:**

- Availability - per-section enforceability

### plan_landlock

```teal
function plan_landlock(fs: Fs, keep_coverage?: boolean): RestrictOptions
```

 Translate an fs policy to `cosmic.landlock.restrict` options. Pure:
 no syscalls, no side effects — exported so the mapping is
 inspectable and unit-testable. `no_new_privs` is set so landlock
 applies without CAP_SYS_ADMIN. An empty or nil policy produces an
 empty rules list, which denies everything when applied.

**Parameters:**

- `fs` (Fs) - nil treated as empty (deny-all)
- `keep_coverage` (boolean?) - Skip the pre-restrict coverage seal

**Returns:**

- RestrictOptions - options for cosmic.landlock.restrict

### validate

```teal
function validate(policy: Policy): boolean, string
```

 Validate a policy's structure without enforcing anything: section
 shapes, path-list types, and promise tokens. `apply` runs this
 itself; it is exported so a policy carried across a process
 boundary (e.g. cosmic.quicksand.Box) can be rejected at
 construction time instead of dying post-fork.

**Parameters:**

- `policy` (Policy) - the policy to check

**Returns:**

- boolean - True when structurally valid
- string? - Error message on failure

### apply

```teal
function apply(policy: Policy): Availability | nil, string
```

 Apply a sandbox policy to the current process. Irreversible.
 The policy is validated and this host's enforceability checked for
 every requested section *before* anything is applied, so a failure
 return means nothing changed. Sections then apply in enforced
 order: `fs` first (landlock on Linux, unveil on OpenBSD), `sys`
 (pledge) second — the reverse would let the pledge filter block the
 filesystem-sandbox syscalls.
 Fail-closed: a requested section this host cannot enforce returns
 `nil, "sandbox: ... unsupported on this host"`. With
 `best_effort = true` unenforceable sections are skipped instead —
 and the return value says so: on success apply returns an
 Availability record of what was actually enforced, so a
 best_effort caller can log or refuse when `.fs`/`.sys` came back
 false rather than believing in a sandbox that is not there.

**Parameters:**

- `policy` (Policy) - fs and/or sys sections, best_effort flag

**Returns:**

- Availability? - What was enforced, on success
- string? - Error message on failure
