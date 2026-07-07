# types

 Shared record and enum types for the cosmic.quicksand family.

 One definition each for the policy records that cross module
 boundaries (the Box schema, the host Capabilities report), so the
 umbrella, the Box builder, and the fork/exec orchestrator all name
 the same nominal types instead of threading `{string: any}` maps.
 Type-only: the module value carries no functions.

## Types

### NetRule

 A single allowlist rule for `net.allow`. Mirrors
 cosmic.quicksand.proxy.ProxyRule (whose looser runtime schema is
 validated by proxy.start) — empty table = pass-through.

```teal
local record NetRule
  type: NetRuleType
  token: string
  username: string
  password: string
  header_name: string
  header_value: string
end
```

### NetOpts

```teal
local record NetOpts
  proxy_env: boolean
  allow: {string: NetRule}
  log_level: LogLevel
  resolve_timeout_ms: integer
end
```

### ProcOpts

```teal
local record ProcOpts
  no_new_privs: boolean
  uid: integer
  gid: integer
  pledge: string
  drop_caps: boolean
  keep_caps: {string}
end
```

### EnvOpts

 Env policy for the boxed workload: `keep` names inherit from the
 parent environment (everything else is dropped), `set` overrides /
 adds. Consumed by cosmic.quicksand.box.env.

```teal
local record EnvOpts
  keep: {string}
  set: {string: string}
end
```

### BoxOpts

 Full box policy. Every field is optional; omitting a section skips
 that subsystem. Scalars default to nil (i.e. no policy); list fields
 default to empty.

```teal
local record BoxOpts
  hostname: string
  fs: FsOpts
  net: NetOpts
  proc: ProcOpts
  env: EnvOpts
  cwd: string
  pid_ns: boolean
end
```

### Capabilities

 Fine-grained feature availability on the current host, as reported
 by cosmic.quicksand.capabilities(). Every field is a boolean.
 Higher-level helpers use these to fail fast with a specific reason
 instead of bailing out on ENOSYS partway through a setup sequence.

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

### TypesModule
