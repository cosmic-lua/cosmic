# init

 Network + filesystem process isolation primitives.

 cosmic.quicksand is the umbrella for Linux-specific box assembly:
 network-namespace setup (cosmic.quicksand.netns), an allowlist
 HTTP/CONNECT proxy (cosmic.quicksand.proxy), and after-fork process
 primitives (cosmic.quicksand.proc). The boxed workload applies the
 `cosmic.sandbox` facade (landlock + pledge) for its fs and syscall
 policy; use that module directly to sandbox in-process.

 This module (the umbrella) probes the host for fine-grained feature
 availability so callers can fail fast with a specific reason instead
 of bailing partway through setup on ENOSYS. It also re-exports the
 declarative Box builder (cosmic.quicksand.box) that composes the
 primitives into a single run() call.

 Linux-only at runtime. Non-Linux hosts see `capabilities().linux ==
 false` and all submodule calls return ENOSYS-shaped errors.

## Types

### Capabilities

 Fine-grained feature availability on the current host.
 Every field is a boolean. Higher-level helpers use these to fail
 fast with a specific reason instead of bailing out on ENOSYS
 partway through a setup sequence.

```teal
local record Capabilities
  linux: boolean
  user_ns: boolean
  mount_ns: boolean
  net_ns: boolean
  uts_ns: boolean
  pid_ns: boolean
  pivot_root: boolean
  cap_net_admin: boolean
  landlock: boolean
  pledge: boolean
  unveil: boolean
  caps: boolean
end
```

### BoxIface

 The typed surface of the re-exported Box builder (the box module's
 own record type is not directly nameable from here).

```teal
local record BoxIface
  new: function(opts?: box.BoxOpts): box.Box | nil, string
  merge: function(...: box.BoxOpts): box.BoxOpts
end
```

### QuicksandModule

```teal
local record QuicksandModule
  capabilities: function(): Capabilities
  is_supported: function(): boolean
  probe: function(fn: any): boolean
  probe_ns: function(): boolean
  Box: BoxIface
end
```

## Functions

### probe

```teal
function probe(fn: any): boolean
```

 Probe a pledge/unveil-style binding with a no-op call: available
 when the call succeeds, or fails with anything other than ENOSYS
 (a policy error still proves the syscall is wired up). A nil binding
 (not exported on this host) reports unavailable.
 This classification is only correct because a failed `unix.*` call
 reports its error (the Phase 0 annotation fix gave it an error slot;
 the binding now returns `nil, err (string), errno (number)`): before
 that fix the error was swallowed and every probe reported available
 (fail-open, audit §2.3). The numeric errno in the third return slot
 is what classifies ENOSYS. Exported so the classifier is
 unit-testable against synthetic ENOSYS / policy-error / success
 returns.

**Parameters:**

- `fn` (any) - the binding to probe (e.g. `unix.pledge`), or nil

**Returns:**

- boolean - true when the syscall is wired up on this host

### probe_ns

```teal
function probe_ns(): boolean
```

 Probe whether the Box namespace trio can actually be entered: a
 scratch child attempts unshare(CLONE_NEWUSER | CLONE_NEWNET |
 CLONE_NEWNS) followed by the uid_map / gid_map writes — exactly the
 setup sequence Box:run's supervisor performs — and reports the
 outcome over a pipe. unshare is irreversible for the caller, so the
 attempt must never run in this process.
 CLONE_NEWUSER exists as a compile-time constant on every Linux
 build, but hosts routinely disable unprivileged user namespaces
 (sysctls, seccomp, AppArmor), and others allow the unshare while
 blocking the /proc/self/*_map writes; testing the constant reported
 user_ns = true on such hosts and Box:run then failed partway
 through setup with EPERM. Any probe failure (pipe, fork, unshare,
 map writes) reports unavailable — fail-closed.

**Returns:**

- boolean - true when the Box userns setup sequence works here

### capabilities

```teal
function capabilities(): Capabilities
```

 Returns a cached Capabilities record for the current host.
 Higher-level helpers use this to fail fast with a specific reason
 rather than bail out on ENOSYS partway through a setup sequence.
 Repeated calls return the same table.

### is_supported

```teal
function is_supported(): boolean
```

 True when the namespace-based box primitives can do real work
 (Linux host with net + mount namespaces). Prefer capabilities()
 for fine-grained checks.
