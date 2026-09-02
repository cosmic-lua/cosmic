# Narrow a nil union

how to turn a `T | nil` into a `T` before you index it. for a reader
whose check failed with `cannot index key ... of type T | nil`.

the checker refuses an index (`s:upper()`, `t.field`, `a[i]`) on an
unnarrowed union. pick the first step below that fits the code.
`cosmic --docs reference.narrowing` has the full table of what narrows.

## 1. guard with truthiness

wrap the use in `if v then`. the variable is `T` inside the branch.

```teal
local fs = require("cosmic.fs")

local st = fs.stat("/tmp")
if st then
  print(st:is_dir())
end
```

the left operand of `and` is the same guard, in a condition or in
value position:

```teal
local fs = require("cosmic.fs")

local st = fs.stat("/tmp")
if st and st:is_dir() then
  print("directory")
end
local size = st and st:size()
print(size)
```

## 2. return early

when the function cannot continue without the value, exit the branch
and use the value below it. `return`, `break`, `goto`, `error(...)` and
`os.exit(...)` all end the branch.

```teal
local fs = require("cosmic.fs")

local function line_count(path: string): integer | nil, string
  local data, err = fs.read(path)
  if not data then
    return nil, "read failed: " .. tostring(err)
  end
  local n = 0
  for _ in data:gmatch("\n") do
    n = n + 1
  end
  return n
end

local n, err = line_count("notes.txt")
print(n, err)
```

## 3. assert the value

use `assert` in a script or a test, where a failure is meant to stop
the program. the value is `T` below the statement:

```teal
local net = require("cosmic.net")

local sock = net.dial("127.0.0.1", 80)
assert(sock, "connect failed")
local _sent, _err = sock:send("hello")
```

`assert` also narrows in expression position. wrap the fallible call
and the local is `T`:

```teal
local sqlite = require("cosmic.sqlite")

local db = assert(sqlite.open(":memory:"))
assert(db:exec("CREATE TABLE t (x TEXT)"))
```

in tests and examples use `check.must` instead. it narrows the same
way and the failure message is the callee's own error string:

```teal
local check = require("cosmic.check")
local sqlite = require("cosmic.sqlite")

local db = check.must(sqlite.open(":memory:"))
check.must(db:exec("CREATE TABLE t (x TEXT)"))
```

## 4. compare with `~= nil` for a union with `boolean`

truthiness and `assert` do not narrow a union that contains `boolean`,
because `false` is falsy. `~= nil` is an exact test and narrows it:

```teal
local function flag(): boolean | nil
  return true
end

local b: boolean | nil = flag()
if b ~= nil then
  local on: boolean = b
  print(on)
end
```

`== nil` in an early exit narrows below it the same way.

## 5. supply a fallback with `or`

when a default is correct, `or` with a non-nil right operand gives the
plain type:

```teal
local fs = require("cosmic.fs")

local text = fs.read("/etc/hostname") or ""
print(text:upper())
```

the fallback must not be nilable itself. `first() or second()` stays
a union when both can return nil.

## 6. copy a record field to a local

a guard on a record field does not narrow the field. copy the field to
a local and guard the local:

```teal
local record Report
  earliest: integer | nil
end
local report: Report = {earliest = 3}

local earliest = report.earliest
if earliest then
  print(earliest + 1)
end
```

## 7. dispatch on shape with `is`

when the code branches over several shapes, or the value is `any`,
`is` narrows inside the positive branch:

```teal
local json = require("cosmic.json")

local items = json.decode_array('[{"name": "cosmic"}]')
if items is {any} then
  for _, raw in ipairs(items) do
    if raw is {string: any} then
      print(raw["name"])
    end
  end
end
```

`is` works on a `cosmic.*` record whose values are userdata too, such
as `fs.Stat`:

```teal
local fs = require("cosmic.fs")

local st = fs.stat("/tmp")
if st is fs.Stat then
  print(st:size())
end
```

## 8. cast as the last resort

when you know more than the checker and no guard fits, cast with `as`.
write the reason on the same line or the line above. the `cast-justify`
lint refuses a cast without it.

```teal
local json = require("cosmic.json")

local input = '{"count": 2}'
local result = json.decode(input) as {string: any} -- cast: from any
print(result["count"])
```

a cast you cannot justify in a few words is a cast to replace with one
of the steps above.

## a guard that stops working

a narrow does not survive into a closure that assigns the variable.
when a nested function writes to the guarded local, copy the value to
a fresh local before the closure, or guard again inside it.
