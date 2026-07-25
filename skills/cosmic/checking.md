# Type Checking

cosmic uses Teal's strict mode for type checking. all type errors must be resolved before code is merged.

## Running Type Checks

```bash
cosmic --check-types file.tl    # check a single file
cosmic --make check             # type-check the whole project
cosmic --make check db/         # …or one subtree
```

`--check-types` runs Teal in strict mode. it reports errors and warnings on stderr. exit code 0 means the file passes. warnings are treated as errors: an unused local, shadowed variable, or unreachable branch fails the check. mark a deliberately-unused value with a leading underscore (`local _out`, `_self: Poller`) to suppress the unused warning.

### Checking a Whole Project

`cosmic --make check` runs the same strict check over every `.tl` source
a project has, in process — no Makefile, no host toolchain, one binary.
it validates the project's shape first (import paths, filenames) and
ends in a verdict line:

```
make: root=/home/you/myapp
check: PASS (12 files)
```

see `cosmic --docs guide.make` for the project model and the validator's
messages.

## Type Annotations

### Basic Types

```teal
local x: number = 42
local name: string = "hello"
local flag: boolean = true
local items: {string} = {"a", "b"}        -- array of strings
local map: {string: number} = {x = 1}     -- map
```

### Optional Types

```teal
local function read(path: string, size?: number): string, string
  -- size is optional (may be nil)
end

local value: string = nil  -- ERROR: string cannot be nil
```

use `?` on parameters to make them optional. for nullable local variables, use the nil-returning pattern from the function signature.

### Narrowing and Casting

record and map nil-unions do not narrow through truthiness. where the code
branches, prefer `is` — it narrows inside the positive branch and compiles
to a single `type()` check:

```teal
local sock = net.connect_tcp(host, port) -- Socket | nil
if sock is net.Socket then
  sock:send("hello")                     -- narrowed, no cast
end
```

a record whose runtime values are userdata needs Teal's `userdata` member
in its own source (see `re.tl`'s Regex) — then `is` compiles to a
`type() == "userdata"` test everywhere. caveats: narrowing does not
survive an early-exit guard (`if not (x is Rec) then return end` does not
narrow below it); do not use `is` with a required `cosmo.*` class — the
runtime tl loader can lax-recompile a module where the required `.d.tl`
marker doesn't resolve, silently degrading `is` to a table test — keep
casts at those boundaries; and `is` is wrong for mixed-representation
records like `fs.Stat` (usually the raw userdata, sometimes a wrapper
table). in linear code, use `as` to cast when you know more than the
type checker:

```teal
local result = json.decode(input) as {string: any}
local count = value as integer
```

per-file `as` counts are pinned by the cast ratchet (`_build/casts.txt`,
enforced by `bin/make lint`). a new cast means raising the pin deliberately;
removing casts means `bin/make casts-baseline` to lock the improvement in.

### Record Types

records define structured data with typed fields and methods:

```teal
local record Point
  x: number
  y: number
end

local record Handle
  pid: number
  wait: function(self: Handle): number, string
  read: function(self: Handle, size?: number): string, string
end
```

### Module Interface Records

every module declares its public API as a record:

```teal
local record JsonModule
  decode: function(str: string): any, string
  encode: function(value: any): string, string
end

local M: JsonModule = { decode = decode, encode = encode }
return M
```

### Function Types

```teal
-- standalone
local function add(a: number, b: number): number
  return a + b
end

-- multiple return values (the value, error pattern)
local function parse(s: string): number, string
  local n = tonumber(s)
  if not n then
    return nil, "not a number"
  end
  return n
end

-- generic functions
local function identity<T>(x: T): T
  return x
end
```

### Global Declarations

test files may declare globals that come from the test environment:

```teal
global TEST_TMPDIR: string
global TEST_BIN: string
```

## Common Type Errors

**"cannot use nil"**: Teal strict mode requires handling nil. check return values:

```teal
-- WRONG: data might be nil
local data = fs.read(path)
print(#data)  -- error if data is nil

-- RIGHT: handle the nil case
local data, err = fs.read(path)
if not data then
  error("read failed: " .. err)
end
print(#data)
```

**"unknown variable"**: all variables must be declared with `local` or `global`.

## Include Directories

`cosmic --check-types` searches for type definitions in the binary's bundled paths. if your project has its own `.d.tl` type definitions, place them in a `types/` directory and they will be found automatically.
