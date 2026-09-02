# Teal annotations

the Teal type annotations a cosmic program uses, with the strict-mode
rules the checker applies. for a reader who knows Lua and wants the
type facts. the Teal language reference at
`github.com/teal-language/tl` covers the whole language.

## basic types

| type | values |
|---|---|
| `integer` | Lua integers |
| `number` | Lua floats and integers |
| `string` | strings |
| `boolean` | `true`, `false` |
| `nil` | `nil` only |
| `any` | any value; cannot be indexed or iterated without a cast or `is` |
| `{T}` | an array of `T` |
| `{K: V}` | a map from `K` to `V` |
| `{T1, T2}` | a tuple |
| `thread` | a coroutine |
| `userdata` | a userdata value |

```teal
local x: number = 42
local name: string = "hello"
local flag: boolean = true
local items: {string} = {"a", "b"}
local map: {string: number} = {x = 1}
print(x, name, flag, items[1], map.x)
```

a local with an initializer takes the initializer's type. a local
without one takes `nil` unless it is annotated.

## `integer` and `number`

`integer` is a subtype of `number`. an `integer` value is accepted
where `number` is declared; a `number` is refused where `integer` is
declared.

| operator | result |
|---|---|
| `+`, `-`, `*`, `//`, `%` on two integers | `integer` |
| `/` | `number` |
| `^` | `number` |
| `#` | `integer` |

a string index (`string.sub`, `string.byte`), a table index, and a
length take `integer`. `math.tointeger(n)` converts a `number` and
returns `integer | nil`.

```teal
local i: integer = 3
local n: number = i
print(n, 7 // 2, 7 / 2, math.tointeger(2.0) or 0)
```

## optional parameters and nilable locals

a `?` after a parameter name makes the parameter optional. its type
inside the function is `T | nil`.

```teal
local function read(path: string, size?: integer): string
  if size then
    return path:sub(1, size)
  end
  return path
end

print(read("notes.txt", 4))
```

a nilable local is annotated `T | nil` at its declaration:

```teal
local value: string | nil = nil
value = "set"
print(value)
```

`local x = nil` with no annotation has the type `nil` forever. every
later assignment fails with `in assignment: got <T>, expected nil`.

## records

a record declares typed fields. a record field may be a function type
with `self` as its first parameter, which a colon call satisfies.

```teal
local record Point
  x: number
  y: number
end

local record Handle
  pid: integer
  wait: function(self: Handle): integer, string
  read: function(self: Handle, size?: integer): string, string
end

local origin: Point = {x = 0, y = 0}
print(origin.x, origin.y)
```

a record may declare `userdata` as its first member. `is` on that
record then compiles to `type(v) == "userdata"`.

## enums

an enum is a closed set of string values:

```teal
local enum Color
  "red"
  "green"
end

local c: Color = "red"
print(c)
```

## module interface records

a module declares its public API as a record and returns a value of
that type:

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

a standalone top-level `local record` is visible only inside its file.
a type another file names as `store.Task` must be a member of the
interface record: a nested `record Task ... end`, or an alias
`type Task = Task` when the record stays standalone.

```teal
local record Task
  id: integer
end

local record StoreModule
  type Task = Task
  record Options
    limit: integer
  end
  add: function(id: integer, opts?: Options): Task
end

local function add(id: integer, opts?: StoreModule.Options): StoreModule.Task
  print(opts and opts.limit)
  return {id = id}
end

local M: StoreModule = {add = add}
return M
```

## function types and multiple returns

a function type lists parameter types and return types. a function
declares every value it returns; a fallible function declares two.

```teal
local function add(a: number, b: number): number
  return a + b
end

local function parse(s: string): number, string
  local n = tonumber(s)
  if not n then
    return nil, "not a number"
  end
  return n
end

local fn: function(integer): integer = function(n: integer): integer
  return n + 1
end

print(add(1, 2), parse("3"), fn(1))
```

a fallible value is declared `T | nil, string`; a fallible effect is
declared `boolean, string`. `cosmic --docs reference.errors` has the
shapes.

a call in the last argument position spreads every declared return
into the argument list. `(f(x))` truncates it to the first.

## generics

a type variable is declared in angle brackets after the name of a
function or a record (`record Pair<K, V>`), and the checker infers it
at each call:

```teal
local function identity<T>(x: T): T
  return x
end

local function first<T>(xs: {T}): T | nil
  return xs[1]
end

print(identity("x"), first({1, 2}))
```

## `global` declarations

a global the file does not define is declared with `global` and a type.
test files declare the two the test runner sets:

```teal
global TEST_TMPDIR: string
global TEST_BIN: string
```

`TEST_TMPDIR` is the test's own temporary directory. `TEST_BIN` is the
path of the cosmic binary under test. every other variable is declared
with `local`; an undeclared name reports `unknown variable`.

## strict mode

`--check types`, `--compile-strict`, and every `--make` gate run the
checker in strict mode.

| rule | consequence |
|---|---|
| warnings are errors | an unused local, an unused argument, or a shadowed name fails the check |
| `_` prefix marks deliberate non-use | `local _out`, `_self: Poller` raise no warning |
| a fallible call as a bare statement | `discarded error return` |
| a fallible call spread into a variadic call | `error return ... spills into the enclosing call` |
| an index on `T \| nil` | `cannot index key` |
| an `as` cast without `-- cast: <reason>` | the `cast-justify` lint fails |

`cosmic --docs howto.check` says how to run the check.
`cosmic --docs howto.type-errors` has the fix for each message.
