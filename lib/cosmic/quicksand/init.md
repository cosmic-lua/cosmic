# init

 Network + filesystem process isolation primitives.

 cosmic.quicksand is the umbrella for Linux-specific jail assembly:
 network-namespace setup (cosmic.quicksand.netns), an allowlist
 HTTP/CONNECT proxy (cosmic.quicksand.proxy), and after-fork process
 primitives (cosmic.quicksand.proc). Pair it with the top-level
 `cosmic.landlock`, `cosmic.pledge`, and `cosmic.unveil` modules to
 compose a full sandbox.

 This module (the umbrella) exposes a capability probe so callers
 can fail fast with a specific reason instead of bailing partway
 through setup on ENOSYS.

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
end
```

### QuicksandModule

```teal
local record QuicksandModule
  capabilities: function(): Capabilities
  is_supported: function(): boolean
end
```

## Functions

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

 True when the namespace-based jail primitives can do real work
 (Linux host with net + mount namespaces). Kept for backwards
 compatibility with cosmo.sandbox.is_supported(); prefer
 capabilities() for fine-grained checks.
