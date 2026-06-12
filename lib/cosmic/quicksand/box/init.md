# init

 Declarative box builder.

 Composes the quicksand primitives (netns, proxy, proc) plus
 cosmic.landlock / cosmic.pledge into a single `box:run(argv)` call
 that returns an exit code.

 Usage:

     local quicksand = require("cosmic.quicksand")
     local box = quicksand.Box.new{
       fs = { ro = { "/usr" }, rw = { "/tmp" } },
       net = { allow = { ["api.example.com:443"] = {} } },
       proc = { no_new_privs = true },
       cwd = "/tmp",
     }
     os.exit(assert(box:run({ "/usr/bin/bash", "-c", "make test" })))

 Options are plain tables, composable with `Box.merge(base, over)`.
 Full schema in `BoxOpts` below.

 The capability probe is loaded lazily to avoid a require cycle with
 cosmic.quicksand (which re-exports Box from its umbrella). The
 fork / exec orchestration lives in cosmic.quicksand.box.run and is
 required on demand from `run()` so construction stays cheap.

## Types

### CapsModule

```teal
local record CapsModule
  capabilities: function(): {string: boolean}
end
```

### NetRule

 A single allowlist rule for `net.allow`. Mirrors
 cosmic.quicksand.proxy.ProxyRule — empty table = pass-through.

```teal
local record NetRule
  type: string
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
  log_level: string
  resolve_timeout_ms: integer
end
```

### FsOpts

```teal
local record FsOpts
  ro: {string}
  rw: {string}
  exec: {string}
  deny: {string}
end
```

### ProcOpts

```teal
local record ProcOpts
  no_new_privs: boolean
  uid: integer
  gid: integer
  pledge: string
end
```

### EnvOpts

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

### Box

 Box instance. `run(argv)` returns an integer exit code on success
 or nil + error on failure. `close()` releases any parent-held
 resources; idempotent and safe to call after `run`.

```teal
local record Box
  opts: BoxOpts
  _closed: boolean
  run: function(self: Box, argv: {string}): integer, string
  close: function(self: Box): boolean
end
```

### RunModule

```teal
local record RunModule
  run: function(opts: {string: any}, argv: {string}): integer, string
end
```

### BoxModule

```teal
local record BoxModule
  new: function(opts?: BoxOpts): Box, string
  merge: function(...: BoxOpts): BoxOpts
end
```

## Functions

### run

```teal
function run(self: Box, argv: {string}): integer, string
```

### new

```teal
function new(opts?: BoxOpts): Box, string
```

 Build a Box from an options table. Validates structural shape; a
 bad `opts` returns nil + error without touching syscalls.

**Parameters:**

- `opts` (BoxOpts?) - policy (all fields optional)

**Returns:**

- Box? - box instance on success
- string? - error message on failure

### merge

```teal
function merge(...: BoxOpts): BoxOpts
```

 Compose policy tables left-to-right. Scalars: later wins. Lists
 (fs.ro, fs.rw, fs.exec, fs.deny, env.keep): concat + dedupe. Maps
 (net.allow, env.set): per-key later wins. Returns a fresh table
 suitable for `Box.new`.

**Parameters:**

- `...` (BoxOpts) - policy tables; nil entries are skipped

**Returns:**

- BoxOpts - merged policy
