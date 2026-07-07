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
       fs = { ro = { "/usr" }, rw = { "/tmp" } },
       sys = { promises = "stdio rpath wpath" },
     })

 Like the mechanism modules, the facade is fail-closed: a section
 that cannot be enforced on this host makes `apply` return
 `false, "sandbox: ... unsupported on this host"` before anything is
 applied, unless `best_effort = true` opts into skipping unenforceable
 sections. `available()` reports what this host can enforce.

 Applying is irreversible and process-wide; policies can only be
 narrowed by further calls. `cosmic.quicksand.Box` consumes the same
 `fs` schema for its boxed workloads.

## Types

### Fs

 Filesystem policy: path allowlists. Everything not listed is denied
 once the policy applies. `ro` paths are readable *and executable*
 (so binaries under read-only roots can run); `rw` paths are
 readable and writable, including creating and removing entries, but
 never executable; `exec` is an alias of `ro` that documents intent.
 A path listed in several groups gets the union of their access.

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
end
```

### Availability

 What this host can enforce: `fs` (landlock on Linux, unveil on
 OpenBSD) and `sys` (pledge).

```teal
local record Availability
  fs: boolean
  sys: boolean
end
```

### SandboxModule

```teal
local record SandboxModule
  apply: function(policy: Policy): boolean, string
  available: function(): Availability
  plan_landlock: function(fs: Fs): RestrictOptions
end
```

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
function plan_landlock(fs: Fs): RestrictOptions
```

 Translate an fs policy to `cosmic.landlock.restrict` options. Pure:
 no syscalls, no side effects — exported so the mapping is
 inspectable and unit-testable. `no_new_privs` is set so landlock
 applies without CAP_SYS_ADMIN. An empty or nil policy produces an
 empty rules list, which denies everything when applied.

**Parameters:**

- `fs` (Fs) - nil treated as empty (deny-all)

**Returns:**

- RestrictOptions - options for cosmic.landlock.restrict

### apply

```teal
function apply(policy: Policy): boolean, string
```

 Apply a sandbox policy to the current process. Irreversible.
 The policy is validated and this host's enforceability checked for
 every requested section *before* anything is applied, so a failure
 return means nothing changed. Sections then apply in enforced
 order: `fs` first (landlock on Linux, unveil on OpenBSD), `sys`
 (pledge) second — the reverse would let the pledge filter block the
 filesystem-sandbox syscalls.
 Fail-closed: a requested section this host cannot enforce returns
 `false, "sandbox: ... unsupported on this host"`. With
 `best_effort = true` unenforceable sections are skipped instead and
 apply reports success for the sections that did enforce.

**Parameters:**

- `policy` (Policy) - fs and/or sys sections, best_effort flag

**Returns:**

- boolean - True on success
- string? - Error message on failure
