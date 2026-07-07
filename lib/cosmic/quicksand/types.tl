--- Shared record and enum types for the cosmic.quicksand family.
---
--- One definition each for the policy records that cross module
--- boundaries (the Box schema, the host Capabilities report), so the
--- umbrella, the Box builder, and the fork/exec orchestrator all name
--- the same nominal types instead of threading `{string: any}` maps.
--- Type-only: the module value carries no functions.
local sandbox = require("cosmic.sandbox")

--- Authentication schemes a `net.allow` rule can inject.
local enum NetRuleType
  "bearer"
  "basic"
  "header"
end

--- Proxy log verbosity.
local enum LogLevel
  "quiet"
  "info"
  "debug"
end

--- A single allowlist rule for `net.allow`. Mirrors
--- cosmic.quicksand.proxy.ProxyRule (whose looser runtime schema is
--- validated by proxy.start) — empty table = pass-through.
local record NetRule
  type: NetRuleType
  token: string
  username: string
  password: string
  header_name: string
  header_value: string
end

local record NetOptions
  proxy_env: boolean -- set HTTP(S)_PROXY in the child env
  allow: {string: NetRule}
  log_level: LogLevel
  resolve_timeout_ms: integer -- per-dial DNS budget; <=0 opts out
end

--- The filesystem policy is cosmic.sandbox's Fs schema (ro/rw/exec
--- path allowlists) — one vocabulary for boxed and in-process
--- sandboxes. The boxed workload applies it via sandbox.apply after
--- fork, before exec.
local type FsOpts = sandbox.Fs

local record ProcOptions
  no_new_privs: boolean
  uid: integer
  gid: integer
  pledge: string
  drop_caps: boolean -- drop the entire capability bounding set before exec
  keep_caps: {string} -- capability names to retain (implies drop_caps)
end

--- Env policy for the boxed workload: `keep` names inherit from the
--- parent environment (everything else is dropped), `set` overrides /
--- adds. Consumed by cosmic.quicksand.box.env.
local record EnvOptions
  keep: {string}
  set: {string: string}
end

--- Full box policy. Every field is optional; omitting a section skips
--- that subsystem. Scalars default to nil (i.e. no policy); list fields
--- default to empty.
local record BoxOptions
  hostname: string
  fs: FsOpts
  net: NetOptions
  proc: ProcOptions
  env: EnvOptions
  cwd: string
  pid_ns: boolean -- set false to opt out of CLONE_NEWPID isolation
end

--- Fine-grained feature availability on the current host, as reported
--- by cosmic.quicksand.capabilities(). Every field is a boolean.
--- Higher-level helpers use these to fail fast with a specific reason
--- instead of bailing out on ENOSYS partway through a setup sequence.
local record Capabilities
  linux: boolean -- host is Linux
  user_ns: boolean -- unshare(NEWUSER|NEWNET|NEWNS) + uid_map verified in a scratch child
  mount_ns: boolean -- CLONE_NEWNS available
  net_ns: boolean -- CLONE_NEWNET available
  uts_ns: boolean -- CLONE_NEWUTS available (for hostname isolation)
  pid_ns: boolean -- CLONE_NEWPID available
  pivot_root: boolean -- unix.pivot_root exported
  cap_net_admin: boolean -- holds CAP_NET_ADMIN (e.g. effective uid 0)
  landlock: boolean -- kernel advertises landlock ABI >= 1
  pledge: boolean -- unix.pledge non-ENOSYS (Linux via seccomp + OpenBSD)
  unveil: boolean -- unix.unveil non-ENOSYS (OpenBSD, or Linux+Landlock)
  caps: boolean -- prctl capability bounding-set API available (PR_CAPBSET_*)
end

local record TypesModule
  type NetRuleType = NetRuleType
  type LogLevel = LogLevel
  type NetRule = NetRule
  type NetOptions = NetOptions
  type FsOpts = FsOpts
  type ProcOptions = ProcOptions
  type EnvOptions = EnvOptions
  type BoxOptions = BoxOptions
  type Capabilities = Capabilities
end

local M: TypesModule = {}

return M
