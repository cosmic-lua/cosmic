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

 Fail-closed: an unenforceable section makes `apply` return `nil,
 "sandbox: ... unsupported on this host"` before anything is
 applied, unless `best_effort = true` skips it instead. Success
 returns a `Report`: one `Section` per requested section, each
 saying `state` — `"full"`, `"degraded"` (landlock enforced, but
 this kernel's ABI stripped some requested rights), or `"skipped"` —
 plus which mechanism enforced it and what is missing. A
 best_effort apply that skips EVERY section refuses outright (`nil,
 "sandbox: nothing enforced (...)"`) unless `allow_unenforced =
 true` says the caller expects that. `strict = true` goes the other
 way: any section that would end degraded or skipped is a refusal
 instead (see [D40](../../docs/decisions/d40-sandbox-enforcement-report.md)).
 `availability()` reports what this host can enforce, per section;
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
 must be present. `best_effort` skips unenforceable sections instead
 of failing closed; `allow_unenforced` additionally tolerates every
 section ending up skipped (only meaningful with `best_effort`).
 `strict` refuses any section that would end degraded or skipped
 (mutually exclusive with both). `no_new_privs` defaults true so the
 Linux fs mechanism works unprivileged.

```teal
local record Options
  fs: Fs
  sys: Sys
  net: Net
  scope: Scope
  best_effort: boolean
  allow_unenforced: boolean
  strict: boolean
  no_new_privs: boolean
end
```

### MechanismInfo

 What this host can enforce for one section: `mechanism` names the
 backend ("landlock" | "unveil" | "pledge"); `abi` is its ABI
 version where that concept exists (0 otherwise).

```teal
local record MechanismInfo
  available: boolean
  mechanism: string
  abi: integer
end
```

### Availability

 Per-section enforceability. `.fs.available` / `.sys.available` are
 the plain booleans most callers want; `.mechanism`/`.abi` say which
 backend and version back that answer. `is_available()` is the AND.

```teal
local record Availability
  fs: MechanismInfo
  sys: MechanismInfo
end
```

### Report

 Per-section report from a successful apply: `fs`/`sys`/`net`/`scope`
 are set exactly when requested. Replaces the old two-boolean shape,
 which could not tell full enforcement from a landlock restrict that
 silently dropped TRUNCATE/REFER.

```teal
local record Report
  fs: Section
  sys: Section
  net: Section
  scope: Section
end
```

### SandboxModule

```teal
local record SandboxModule
  apply: function(opts: Options): Report | nil, string
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

### Net

 Network policy (per-port TCP, Landlock ABI 4+), defined in plan beside its mapping.

alias of `cosmic.sandbox.plan.Net` — field and method table: `cosmic --docs cosmic.sandbox.plan.Net`

### Scope

 Signal / abstract-UNIX-socket scoping (Landlock ABI 6+), defined in plan beside its mapping.

alias of `cosmic.sandbox.plan.Scope` — field and method table: `cosmic --docs cosmic.sandbox.plan.Scope`

### Section

 One section's enforcement result, defined in cosmic.sandbox.section
 beside the code that builds it.

alias of `cosmic.sandbox.section.Section` — field and method table: `cosmic --docs cosmic.sandbox.section.Section`

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
 allow_unenforced, strict, no_new_privs, fs.optional, the sys
 strings) take the later value when set. Returns a fresh Options
 suitable for apply(); nil arguments are skipped.

**Parameters:**

- `...` (Options) - policies to merge, left to right

**Returns:**

- Options - the merged policy

### apply

```teal
function apply(opts: Options): Report | nil, string
```

 Apply a sandbox policy to the current process. Irreversible.
 Validated and checked against this host's enforceability for every
 requested section *before* anything is applied, so a failure return
 means nothing changed. Sections then apply in the only order that
 works: `fs` first (landlock on Linux, unveil on OpenBSD), `sys`
 (pledge) second — the reverse would let the pledge filter block the
 filesystem-sandbox syscalls.
 Fail-closed: a requested section this host cannot enforce returns
 `nil, "sandbox: ... unsupported on this host"`. `best_effort = true`
 skips such sections instead, and the Report says so per section
 (`state == "skipped"`) — unless EVERY requested section ends up
 skipped, in which case apply refuses (`nil, "sandbox: nothing
 enforced (...)"`) rather than return a report nobody asked to trust
 as success; `allow_unenforced = true` is the one named opt-in that
 tolerates that. `strict = true` turns any section that would end
 "degraded" or "skipped" into a refusal instead, before anything is
 applied.

**Parameters:**

- `opts` (Options) - fs, sys, net, and/or scope sections plus tuning flags

**Returns:**

- Report? - What was enforced, on success
- string? - Error message on failure
