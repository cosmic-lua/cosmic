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
 Full schema in `BoxOptions` below.

 The capability probe is loaded lazily to avoid a require cycle with
 cosmic.quicksand (which re-exports Box from its umbrella). The
 fork / exec orchestration lives in cosmic.quicksand.box.run and is
 required on demand from `run()` so construction stays cheap.

## Types

### CapsModule

```teal
local record CapsModule
  capabilities: function(): types.Capabilities
end
```

### Box

 Box instance. `run(argv)` returns an integer exit code on success
 or nil + error on failure. `close()` releases any parent-held
 resources; idempotent and safe to call after `run`.

```teal
local record Box
  opts: BoxOptions
  _closed: boolean
  run: function(self: Box, argv: {string}): integer | nil, string
  close: function(self: Box): boolean
end
```

### RunModule

```teal
local record RunModule
  run: function(opts: BoxOptions, argv: {string}): integer | nil, string
end
```

### BoxModule

```teal
local record BoxModule
  new: function(opts?: BoxOptions): Box | nil, string
  merge: function(...: BoxOptions): BoxOptions
end
```

## Functions

### run

```teal
function run(self: Box, argv: {string}): integer | nil, string
```

### new

```teal
function new(opts?: BoxOptions): Box | nil, string
```

 Build a Box from an options table. Validates structural shape; a
 bad `opts` returns nil + error without touching syscalls.

**Parameters:**

- `opts` (BoxOptions?) - policy (all fields optional)

**Returns:**

- Box? - box instance on success
- string? - error message on failure

### merge

```teal
function merge(...: BoxOptions): BoxOptions
```

 Compose policy tables left-to-right. Scalars: later wins. Lists
 (fs.ro, fs.rw, fs.exec, env.keep): concat + dedupe. Maps
 (net.allow, env.set): per-key later wins. Returns a fresh table
 suitable for `Box.new`.

**Parameters:**

- `...` (BoxOptions) - policy tables; nil entries are skipped

**Returns:**

- BoxOptions - merged policy
