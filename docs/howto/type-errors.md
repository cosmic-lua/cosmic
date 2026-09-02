# Fix a type error

the common checker messages, what causes each, and the fix. for a
reader with a failing `cosmic --check types` run.

each entry is named by its heading slug, and the checker's `hint:`
lines cite the slug. `cosmic --docs howto.check` says how to run the
checker; `cosmic --docs howto.narrow-nil` has every way to narrow a
`T | nil`.

## warnings-are-errors

```text
main.tl:6:7: warning: unused variable out: string
main.tl:1:1: warning: function shadows previous declaration of 'load'
```

strict mode fails the check on any warning. an unused local or
argument, and a name that shadows a Lua builtin, both fail.

remove the unused value, or prefix its name with `_`. rename a local
that shadows `load`, `type`, `error` or another builtin.

```teal
local fs = require("cosmic.fs")

local _out, err = fs.read("notes.txt")
local function load_config(): string
  return "ok"
end
print(err, load_config())
```

## integer-vs-number

```text
main.tl:2:25: error: argument 1: got number, expected integer
```

Teal separates `integer` from `number`. a string index (`string.sub`,
`string.byte`), a length, and a table index take `integer`, and
arithmetic with `/` yields `number`.

annotate the variable `: integer`, or convert at the call site with
`math.tointeger`:

```teal
local x = 2.0

local n: integer = 5
local s = ("hello"):sub(n, n)
local m = ("hello"):sub(math.tointeger(x) or 1, 5)
print(s, m)
```

a `cosmo.*` binding that returns an integral value (an exit status, an
fd, a pid, a size) is declared `integer`, so no conversion is needed
on that side.

## nil-local-declaration

```text
main.tl:2:5: error: in assignment: got integer, expected nil
```

a `local x = nil` with no annotation has the type `nil` forever. every
later assignment fails, and no guard recovers it.

annotate the optional at the declaration:

```teal
local x: integer | nil = nil
x = 3
print(x)
```

## any-from-json-decode

```text
main.tl:3:9: error: cannot index key 'count' in variable 'v' of type <any type>
main.tl:4:22: error: attempting ipairs on something that's not an array: <any type>
```

`json.decode` returns `any`, and `any` cannot be indexed or iterated.

for a top-level object or array, call the typed decoder instead.
`json.decode_object` returns `{string: any} | nil, string` and
`json.decode_array` returns `{any} | nil, string`. input of the wrong
shape is a returned error, not a downstream index failure.

```teal example=cosmic/json_example.tl#Example_decode_object
local json = require("cosmic.json")
local obj = json.decode_object('{"name":"ada","age":36}')
if obj is {string: any} then
  print(obj["name"])
end
-- Output:
-- ada
```

```teal example=cosmic/json_example.tl#Example_decode_array
local json = require("cosmic.json")
local items = json.decode_array("[10,20,30]")
if items is {any} then
  print(#items)
end
-- Output:
-- 3
```

nested values are still `any`. narrow them with `is` when the shape is
uncertain, or cast with `as` and a `-- cast: <reason>` when the shape is
trusted:

```teal
local json = require("cosmic.json")

local items = json.decode_array('[{"name": "cosmic"}]')
if items is {any} then
  for _, raw in ipairs(items) do
    if raw is {string: any} then
      print(raw["name"] as string) -- cast: json string field
    end
  end
end
```

## nilable-arg

`arg` is typed `{string}`, so `arg[1]:upper()` passes the check and
indexes nil at runtime when nobody passed an argument. the checker does
not report this one.

supply the default at the point of use:

```teal
local name = (arg[1] or "default"):upper()
print(name)
```

inside `cosmic.main`, a usage guard is an early return, and the value
narrows below it:

```teal
local cosmic = require("cosmic")

cosmic.main(function(args: {string}, env: cosmic.Env): number, string
    local name = args[1]
    if not name then
      env.stderr:write("usage: myscript <name>\n")
      return 1
    end
    print("hello, " .. name)
    return 0
  end)
```

## multi-return-capture

```text
main.tl:3:20: error: expression in for loop does not return an iterator
main.tl:4:9: error: excess return values
```

a fallible call returns `T | nil, string`. a `for` loop over the call,
or the call wrapped inside another expression, sees the union or
discards the second return.

capture both returns first, then narrow the value:

```teal
local check = require("cosmic.check")
local sqlite = require("cosmic.sqlite")

local db = check.must(sqlite.open(":memory:"))
local rows, err = db:query("SELECT * FROM t")
if not rows then
  return nil, "query failed: " .. tostring(err)
end
for row in rows do
  print(row.id)
end
```

## discarded-error

```text
main.tl:2:9: error: discarded error return of function(...): (boolean, string)
main.tl:2:18: error: error return of function(...): (string | nil, string) spills into the enclosing call
```

a fallible call (returns ending `T | nil, string` or `boolean, string`)
stands as a bare statement, or sits as the last argument of a variadic
call where its error return spills in as an extra argument.

capture the error. name it `_err` for a deliberate fire-and-forget.
parenthesize the call to pass only its first return:

```teal
local fs = require("cosmic.fs")
local json = require("cosmic.json")

local ok, err = fs.write("notes.txt", "hello")
local _ok, _err = fs.write("scratch.txt", "hello")
print(ok, err)
print((json.encode({a = 1})))
```

`assert(fs.write(path, data))` and `check.must(...)` consume the error
themselves, so neither shape fires on them.

## record-fields-dont-narrow

```text
main.tl:9:15: error: cannot index key 'x' in type Inner | nil
```

a guard on a plain variable narrows it. a guard on a record field does
not: after `if o.sub then`, `o.sub` is still `Inner | nil` at the use.

copy the field to a local and guard the local:

```teal
local record Inner
  x: integer
end
local record Outer
  sub: Inner | nil
end
local o: Outer = {sub = {x = 1}}

local sub = o.sub
if sub then
  print(sub.x)
end
```

the same message on a plain variable means the variable was never
guarded. `cosmic --docs howto.narrow-nil` has the guards.

## exported-record-types

```text
main.tl:2:10: error: unknown type store.Task
```

a standalone top-level `local record` is visible only inside its own
file. an importer that writes `store.Task` gets this error at every
use site, while the value-level API works.

nest the record inside the module's interface record. importers then
write `store.Task`:

```teal
local record StoreModule
  record Task
    id: integer
    text: string
  end
  add: function(path: string, text: string): Task | nil, string
end

local function add(path: string, text: string): StoreModule.Task | nil, string
  return {id = 1, text = text .. path}
end
local M: StoreModule = {
  add = add,
}
return M
```

a `type Task = Task` member inside the interface record also exports a
record that must stay standalone. `cosmic.fs` exports `Stat` that way.

## colon-call

```text
main.tl:10:22: error: invalid key 'add' in record 'db' of type Database
```

a colon call looks the method up on the value's own record type. a
function on your module's record is not on the value's type. the same
message also fires on a plain typo.

dot-call the module function with the value first. colon-call only a
function the value's record declares, such as `db:exec` on
`sqlite.Database`:

```teal
local check = require("cosmic.check")
local sqlite = require("cosmic.sqlite")

local record StoreModule
  add: function(db: sqlite.Database, name: string): boolean, string
end
local function add(db: sqlite.Database, name: string): boolean, string
  return db:exec("INSERT INTO people (name) VALUES (?)", {name})
end
local store: StoreModule = {
  add = add,
}

local db = check.must(sqlite.open(":memory:"))
local _ok, _err = store.add(db, "alice")
```

## gsub-replacement

```text
main.tl:3:1: gsub-replacement: main.tl:3: a non-literal gsub replacement interpolates %
```

the check passes; the `gsub-replacement` lint reports it.
`string.gsub`'s replacement is not plain text. `%1` splices a capture
and a lone `%` is a runtime error, so a value with a `%` in it breaks
the call.

use `str.replace` for literal text. it is literal on both sides and
nothing needs escaping:

```teal
local str = require("cosmic.string")
local template = "hello, {{name}}"
local user_name = "cosmic"
local page = str.replace(template, "{{name}}", user_name)
print(page)
```

`cosmic --docs reference.lint` has the escape for a deliberate template.

## tuple-spread

```text
main.tl:4:13: error: wrong number of arguments (given 4, expects 2 or 3)
```

Lua spreads every return of a call in the last argument position into
the argument list, and the checker counts the declared tuple.
`str.partition` declares three returns, so
`table.insert(parts, str.partition(line, "="))` presents four arguments.

parenthesize the call to truncate it to one value:

```teal
local str = require("cosmic.string")

local parts: {string} = {}
local line = "key=value"
table.insert(parts, (str.partition(line, "=")))
```

at runtime the extra returns collapse away when they are `nil`, so the
site can look correct until the check runs. `check.must` declares one
return, so `table.insert(parts, check.must(chunk))` checks clean with
no parentheses. only a function that declares several values spreads
here: an infallible tuple such as `partition`, or a `cosmo.*` binding.

## iterator-early-break

the checker does not report this one. draining `fs.find_iter` closes
every directory handle it opened. a loop that exits early with `break`
or `return` has not drained it, so the handles stay open until garbage
collection. that pins directory fds, and on Windows it can block
deleting the tree just walked.

declare the iterator `<close>`, or call `iter:close()`. the scope exit
then closes the handles wherever the loop stops:

```teal
local check = require("cosmic.check")
local fs = require("cosmic.fs")

local function first_match(dir: string): string | nil
  local iter < close > = check.must(fs.find_iter(dir, {glob = "*.lua"}))
  for f in iter do
    return f
  end
  return nil
end

print(first_match("."))
```

when stopping early is the normal path, use `fs.visit`. its visitor
returns `"stop"`, and `visit` owns the loop and closes the handles on
the way out.
