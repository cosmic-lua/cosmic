# Type Checking

cosmic uses Teal's strict mode for type checking. all type errors must be resolved before code is merged.

## Running Type Checks

```bash
cosmic --check types file.tl    # check a single file
cosmic --make check             # type-check the whole project
cosmic --make check db/         # …or one subtree
```

`--check types` runs Teal in strict mode. it reports errors and warnings on stderr. exit code 0 means the file passes. warnings are treated as errors: an unused local, shadowed variable, or unreachable branch fails the check. mark a deliberately-unused value with a leading underscore (`local _out`, `_self: Poller`) to suppress the unused warning.

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

the early-exit caveat bites hardest in the most idiomatic-looking shape,
so here is the fix, concretely. `if not x then return end` narrows
scalars but NOT records, maps or arrays — below the guard `x` is still
`T | nil`, and the errors that produces do not say why (`cannot index
key 'x' in variable 'r' of type R | nil`, `expression in for loop does
not return an iterator`, `attempting ipairs on something that's not an
array: {T} | nil`):

```teal
local r = make()        -- r: R | nil

-- WRONG: r stays R | nil below this guard
if not r then
  return nil, "no r"
end
print(r.x)              -- error: cannot index key 'x' ... R | nil

-- RIGHT (branching): do the work inside the positive branch, handing
-- it to a helper that takes the narrowed type
if r is R then
  return run(r)         -- run(r: R) receives a plain R
end
return nil, "no r"

-- RIGHT (linear): keep the guard, cast once immediately after it
if not r then
  return nil, "no r"
end
local rr = r as R       -- cast: record union after guard
print(rr.x)
```

scalars narrow through truthiness for plain uses, with one caveat: a
narrowed scalar cannot be METHOD-called. after a nil-guard on `data:
string | nil`, `#data` and `data .. s` work but `data:gmatch(...)`
still fails (`cannot index key 'gmatch' ... string | nil`). use the
function form (`string.gmatch(data, ...)`) or branch with
`if data is string then`.

record FIELDS do not narrow either, even when the field is a scalar:
after `if report.earliest ~= nil then`, `report.earliest` is still
`integer | nil` at the point of use. copy the field to a local first —
the local narrows normally:

```teal
local earliest = report.earliest   -- integer | nil
if earliest ~= nil then
  print(earliest + 1)              -- narrowed; the field read would not be
end
```

per-file `as` counts are pinned by the cast ratchet (`_build/casts.txt`,
enforced by `--make lint`). every cast carries its own `-- cast: <reason>`
on the line or the line above, so there is no baseline to raise: a cast
you cannot justify is one to remove.

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

a TYPE another file needs must be part of that record too: a standalone
top-level `local record Task` is visible only inside its own file, so an
importer writing `store.Task` gets `unknown type store.Task`. nest the
record inside the interface record (`record StoreModule record Task ...
end ... end`), or alias it in with a `type Task = Task` member.

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

`cosmic --check types` searches for type definitions in the binary's bundled paths. if your project has its own `.d.tl` type definitions, place them in a `types/` directory and they will be found automatically.
