# sandbox

 One-call, fail-closed in-process sandbox: the one door.

 cosmic ships two public containment modules: this one (in-process
 self-restriction) and `cosmic.quicksand` (out-of-process boxes).
 The mechanisms behind this facade — landlock (Linux), unveil
 (OpenBSD), pledge (both) — are internal shards under
 cosmic/sandbox/; the facade takes a single declarative policy,
 picks the right mechanism per OS, and applies the sections in the
 only order that works (fs before sys — a pledged process may no
 longer be allowed to install a filesystem sandbox).

     local sandbox = require("cosmic.sandbox")
     assert(sandbox.apply{
       fs = { exec = { "/usr" }, ro = { "/etc" }, rw = { "/tmp" } },
       sys = { promises = "stdio rpath wpath" },
     })

 Fail-closed: a section that cannot be enforced on this host makes
 `apply` return `nil, "sandbox: ... unsupported on this host"`
 before anything is applied, unless `best_effort = true` opts into
 skipping unenforceable sections — in which case the returned
 Availability record reports which sections actually enforced.
 `availability()` reports what this host can enforce;
 `is_available()` is the boolean shorthand.

 Applying is irreversible and process-wide; policies can only be
 narrowed by further calls. `cosmic.quicksand` consumes the same
 `fs`/`sys` schemas for its boxed workloads.

## Types

### Sys

 System-call policy: pledge promise groups as a space-separated
 string (the internal pledge shard's `Promise` enum names every
 valid token). `exec_promises` optionally sets the promises children
 keep after execve — named to avoid reading as a path list beside
 fs.exec.

```teal
local record Sys
  promises: string
  exec_promises: string
end
```

### Options

 A full sandbox policy. Each section is optional but at least one
 must be present. `best_effort = true` skips sections this host
 cannot enforce instead of failing closed. `no_new_privs` and
 `handled` tune the Linux fs mechanism: no_new_privs defaults true
 so the restrict works unprivileged; handled narrows which access
 categories the sandbox controls (default: all of them).

```teal
local record Options
  fs: Fs
  sys: Sys
  best_effort: boolean
  no_new_privs: boolean
  handled: integer
end
```

### Availability

 Per-section enforcement report: `fs` (landlock on Linux, unveil on
 OpenBSD) and `sys` (pledge). `availability()` returns what this
 host *can* enforce; a successful `apply` returns what it *did*
 enforce, so a `best_effort` caller can see exactly which sections
 were skipped instead of flying blind.

```teal
local record Availability
  fs: boolean
  sys: boolean
end
```

### SandboxModule

```teal
local record SandboxModule
  apply: function(opts: Options): Availability | nil, string
  availability: function(): Availability
  is_available: function(): boolean
  validate: function(opts: Options): boolean, string
  merge: function(...: Options): Options
end
```

### Fs

 Filesystem policy; the record (ro/rw/exec allowlists plus
 `optional`) is defined in cosmic.sandbox.plan beside its mapping.

alias of `cosmic.sandbox.plan.Fs` — field and method table: `cosmic --docs cosmic.sandbox.plan.Fs`

## Functions

### availability

```teal
function availability(): Availability
```

 Report what this host can enforce, per section. Sections requested
 in `apply` beyond this fail closed (or are skipped under
 `best_effort`).

**Returns:**

- Availability - per-section enforceability

### is_available

```teal
function is_available(): boolean
```

 True when every section this facade fronts is enforceable here —
 the one boolean predicate covering the whole family. For
 per-section answers use availability().

**Returns:**

- boolean - True when both fs and sys can be enforced

### validate

```teal
function validate(opts: Options): boolean, string
```

 Validate a policy's structure without enforcing anything: section
 shapes, path-list types, and promise tokens. `apply` runs this
 itself; it is exported so a policy carried across a process
 boundary (e.g. cosmic.quicksand) can be rejected at construction
 time instead of dying post-fork.

**Parameters:**

- `opts` (Options) - the policy to check

**Returns:**

- boolean - True when structurally valid
- string? - Error message on failure

### merge

```teal
function merge(...: Options): Options
```

 Compose policies left-to-right, mirroring quicksand's Box merge:
 fs path lists concat and dedupe; scalars (best_effort,
 no_new_privs, handled, fs.optional, the sys strings) take the later
 value when set. Returns a fresh Options suitable for apply(); nil
 arguments are skipped.

**Parameters:**

- `...` (Options) - policies to merge, left to right

**Returns:**

- Options - the merged policy

### apply

```teal
function apply(opts: Options): Availability | nil, string
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

- `opts` (Options) - fs and/or sys sections plus tuning flags

**Returns:**

- Availability? - What was enforced, on success
- string? - Error message on failure
