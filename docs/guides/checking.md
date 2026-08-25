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
local items: {string} = {"a", "b"} -- array of strings
local map: {string: number} = {x = 1} -- map
print(x, name, flag, items[1], map.x)
```

### Optional Types

```teal
local function read(path: string, size?: integer): string | nil, string
  -- size is optional (may be nil)
  if size then
    return path:sub(1, size)
  end
  return path
end

local value: string | nil = nil -- an optional admits nil; a bare `string` does not
print(read("notes.txt", 4), value)
```

use `?` on parameters to make them optional. a nullable LOCAL must be
annotated at its declaration: `local x: integer | nil = nil`. a bare
`local x = nil` infers the type `nil` itself — every later assignment
fails with `in assignment: got ..., expected nil`, and no guard can
recover it.

### Narrowing and Casting

a guard on a plain variable narrows its nil union: truthiness,
`assert(x)`, `x and x.field`, and `== nil` / `~= nil` all narrow
`T | nil` for records, maps, arrays and scalars, in the positive branch
and below a negated early exit alike (the carried tl patch,
`3p/tl/tl_patch.tl`):

```teal
local net = require("cosmic.net")

local record R
  x: integer
end
local function make(): R | nil
  return {x = 1}
end

local r = make() -- r: R | nil
if not r then
  return nil, "no r"
end
print(r.x) -- r is R below the guard

local sock = net.dial("127.0.0.1", 80) -- Socket | nil
assert(sock, "connect failed")
local _sent, _serr = sock:send("hello") -- narrowed, method call included
```

the same fact rides the left operand of `and`, which is where a Lua
programmer usually puts the guard:

```teal
local fs = require("cosmic.fs")

local st = fs.stat("/tmp")
if st and st:is_dir() then
  print("directory")
end
```

that fact rides the whole expression, not just an `if` condition: in
value position — `local port = x and x.port` — the left operand is read
for its truthiness too, because when it is falsy the right operand never
runs.

`assert` also narrows as an EXPRESSION, because it declares that it
strips the nil — so composing it with a fallible call yields the plain
type, and there is nothing cosmic-specific to learn first:

```teal
local sqlite = require("cosmic.sqlite")

local db = assert(sqlite.open(":memory:")) -- Database, not Database | nil
assert(db:exec("CREATE TABLE t (x TEXT)"))
```

that is the same narrowing `check.must` gives, in the primitive you
already know. `check.must` remains the one to reach for in tests and
examples, where the callee's own error string is the failure message.

`~= nil` is exact, so it also narrows unions containing `boolean`,
which truthiness and `assert` deliberately skip (`false` is falsy, so
truthy does not mean "not nil" there):

```teal
local function flag(): boolean | nil
  return true
end

local b: boolean | nil = flag()
if b ~= nil then
  return b -- narrowed to boolean; `if b then` would not narrow
end
```

an early-exit guard narrows below itself whenever its block cannot fall
through, which is more than `return`: `break`, `goto`, `error(...)` and
`os.exit(...)` all end the branch, so the union does not survive any of
them:

```teal
local function next_name(): string | nil
  return "cosmic"
end

while true do
  local name = next_name()
  if not name then break end
  print(name:upper()) -- narrowed below the break-terminated guard
  break
end
```

an `or` fallback disposes of the nil the same way, so the result is the
plain type rather than the union:

```teal
local fs = require("cosmic.fs")

local text = fs.read("/etc/hostname") or ""
print(text:upper()) -- string, not string | nil
```

when BOTH operands can be nil (`first() or second()`), the result stays
a union — neither one disposes of it.

what does NOT narrow: **record FIELDS**, even scalar ones — copy the
field to a local and guard the local:

```teal
local record Report
  earliest: integer | nil
end
local report: Report = {earliest = 3}

local earliest = report.earliest -- integer | nil
if earliest then
  print(earliest + 1) -- narrowed; the field read would not be
end
```

where the code dispatches over shapes (`any`, unions past nil), `is` is
the tool — it narrows inside the positive branch and compiles to a
single `type()` check:

```teal
local net = require("cosmic.net")

local sock = net.dial("127.0.0.1", 80) -- Socket | nil
if sock is net.Socket then
  local _sent, _err = sock:send("hello") -- narrowed, no cast
end
```

a record whose runtime values are userdata needs Teal's `userdata` member
in its own source (see `re.tl`'s Regex) — then `is` compiles to a
`type() == "userdata"` test everywhere; `fs.Stat` declares it, so
`st is fs.Stat` narrows. caveat: `is` with a required `cosmo.*` class
relies on the cosmic searcher resolving the `.d.tl` marker — the one
unsupported path is user code calling `require("tl").loader()`, which
shadows the cosmic searcher with tl's silent one. in linear code, use
`as` to cast when you know
more than the type checker:

```teal
local json = require("cosmic.json")

local input = '{"count": 2}'
local value: any = 2

local result = json.decode(input) as {string: any} -- cast: from any
local count = value as integer -- cast: from any
print(result, count)
```

every cast carries its own `-- cast: <reason>` on the line or the line
above (enforced by `--make lint`): a cast you cannot justify is one to
remove.

### Where Narrowing Is Required

the checker demands a guard in exactly one position: an INDEX. `s:upper()`,
`t.field` and `a[i]` all refuse an unnarrowed `T | nil`. every other position
admits it — assignment to a declared non-nil type, a non-nil parameter,
arithmetic, concatenation:

```teal
local function size_of(path: string): integer | nil
  return #path
end

local function name_of(path: string): string | nil
  return path
end

local function widen(n: integer): integer
  return n + 1
end

local size = size_of("notes.txt")
local declared: integer = size_of("notes.txt")
local label: string = name_of("notes.txt")
print(size + 1, widen(size_of("notes.txt")))
print(name_of("notes.txt") .. "!", declared, label)
```

that snippet compiles at full strictness, which is the point: every line of it
puts a possible nil somewhere a nil cannot go, and nothing objects. index the
same union and the checker finally stops you:

```text
local s = name_of("notes.txt")
print(s:upper())

error: cannot index key 'upper' in variable 's' of type string | nil
```

so a `| nil` annotation is a contract with the reader that the checker only
half enforces. guard where the union is produced — at the call that can fail —
rather than trusting the annotation to force a guard out of every caller
downstream.

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

local origin: Point = {x = 0, y = 0}
print(origin.x, origin.y)
```

### Module Interface Records

every module declares its public API as a record:

```teal
local record JsonModule
  decode: function(str: string): any, string
  encode: function(value: any): string, string
end

local function decode(str: string): any, string
  return str
end
local function encode(value: any): string, string
  return tostring(value)
end

local M: JsonModule = {decode = decode, encode = encode}
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

print(add(1, 2), parse("3"), identity("x"))
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
local fs = require("cosmic.fs")

local path = "notes.txt"
local data, err = fs.read(path)
if not data then
  return nil, "read failed: " .. tostring(err)
end
print(#data) -- narrowed: data is a string here
```

**"unknown variable"**: all variables must be declared with `local` or `global`.

## Discarded Errors

the honest-nil convention puts the error in the second return slot, and
the strict check enforces that callers do not silently drop it. two
shapes are errors:

- a fallible call — declared returns ending `T | nil, string` or
  `boolean, string` — standing as a bare statement:

```teal
local fs = require("cosmic.fs")

local path = "notes.txt"
local data = "hello"

local ok, err = fs.write(path, data) -- capture it
local _ok, _err = fs.write(path, data) -- deliberate fire-and-forget
print(ok, err)
```

- a fallible call as the FINAL argument of a variadic call, where the
  error return spills in as an extra argument:

```teal
local json = require("cosmic.json")

local x = {a = 1}

local encoded, err = json.encode(x) -- capture first
print((json.encode(x))) -- or parenthesize to truncate
print(encoded, err)
```

callees that consume the error are exempt from the spill shape:
`assert(fs.write(path, data))` checks the boolean and reports the
message, and `check.must(...)` is the sanctioned idiom in tests and
examples. the rule runs wherever the strict gate runs — `--check
types`, and the build's strict compile.

## Include Directories

`cosmic --check types` searches for type definitions in the binary's bundled paths. if your project has its own `.d.tl` type definitions, place them in a `types/` directory and they will be found automatically.
