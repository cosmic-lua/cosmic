# quicksand

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

### BoxIface

 The typed surface of the re-exported Box builder (the box module's
 own record type is not directly nameable from here).

```teal
local record BoxIface
  new: function(opts?: box.BoxOptions): box.Box | nil, string
  merge: function(...: box.BoxOptions): box.BoxOptions
end
```

### QuicksandModule

```teal
local record QuicksandModule
  capabilities: function(): Capabilities
  is_supported: function(): boolean
  --  Internal, exported for its own unit tests: pure decision function
  --  over a binding value; never syscalls.
  probe: function(fn: any): boolean
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
 reports its error: the binding returns `nil, err (string), errno
 (number)`, and the numeric errno in that third slot is what
 classifies ENOSYS. Without it the error is swallowed, the ENOSYS
 branch is unreachable, and every probe reports available — fail-open,
 in a capability check. Exported so the classifier is unit-testable
 against synthetic ENOSYS / policy-error / success returns.

**Parameters:**

- `fn` (any) - the binding to probe (e.g. `unix.pledge`), or nil

**Returns:**

- boolean - true when the syscall is wired up on this host

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
