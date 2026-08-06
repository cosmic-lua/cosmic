# Teal Gotchas for Newcomers

common errors that trip up agents and developers new to Teal. each entry shows the wrong pattern, the error it produces, and the fix.

## 1. integer vs number

Teal distinguishes `integer` from `number`. string indices (`string.sub`, `string.byte`, `table` lookups) and some C bindings require `integer`. arithmetic and C status returns are `number`.

**wrong:**
```teal
local n: number = 5
local s = ("hello"):sub(n, n) -- error: got number, expected integer
```

**right:**
```teal
-- option A: annotate the literal as integer
local n: integer = 5
local s = ("hello"):sub(n, n)

-- option B: convert at call site
local n: number = some_computation()
local s = ("hello"):sub(math.tointeger(n), math.tointeger(n))
```

`WEXITSTATUS` and similar status-decoding functions return `number`, not `integer`:
```teal
local code: number = child.WEXITSTATUS(status)
```

## 2. traversing `any` from json.decode

`json.decode` returns `any`. you cannot index or iterate `any` directly — you must cast to a concrete type first.

**wrong:**
```teal
local data = json.decode(input)
for _, item in ipairs(data) do -- error: attempting ipairs on something that's not an array: <any type>
```

**right — `is` when the shape is uncertain** (narrows in the positive
branch, compiles to one `type()` check, and untrusted input that isn't
the expected shape takes the other branch instead of misbehaving later):
```teal
local data = json.decode(input)
if data is {any} then
  for _, raw in ipairs(data) do
    if raw is {string: any} then
      print(raw["name"] as string)
    end
  end
end
```

**right — `as` when the shape is trusted** (a schema you control):
```teal
local obj = json.decode(input) as {string: any}
local tags = obj["tags"] as {string}
```

new casts count against the cast ratchet (`_build/casts.txt`); prefer
the `is` form where the code branches anyway.

## 3. `arg` elements are `string | nil`

the global `arg` table has type `{string | nil}`. accessing `arg[1]` without a guard may give you `nil`, which causes a type error when used where a `string` is expected.

**wrong:**
```teal
local name = arg[1]:upper() -- error: cannot index nil
```

**right:**
```teal
local name = (arg[1] or "default"):upper()

-- or with an explicit check:
if not arg[1] then
  io.stderr:write("usage: myscript <name>\n")
  os.exit(1)
end
local name = (arg[1] as string):upper()
```

## 4. multi-return capture — `db:query` and similar

functions that return `(iterator, state, initial)` (like `db:query`) cannot be wrapped inside another expression — the extra returns are discarded.

**wrong:**
```teal
for row in db:query("SELECT * FROM t"), nil, nil do -- syntax error / wrong returns
```

**right:**
```teal
for row in db:query("SELECT * FROM t") do
  print(row.id)
end
```

if you need to capture both the iterator and an error return, assign to locals first:
```teal
local rows, err = db:query("SELECT * FROM t")
if not rows then
  error("query failed: " .. tostring(err))
end
for row in rows do
  print(row.id)
end
```

## 5. local modules — `require` path resolution

`require("mymod")` resolves relative to the script's directory, not the current working directory. you do not need a `./` prefix (both work).

```teal
-- both are equivalent when mymod.tl is in the same directory:
local m = require("mymod")
local m2 = require("./mymod") -- also works
```

if your module is in a subdirectory:
```teal
local m = require("subdir.mymod") -- loads subdir/mymod.tl
```

## 6. naming `cosmic.fd` as `io`

`require("cosmic.fd")` returns the cosmic.fd module. if you bind it to a local named `io` you shadow Lua's built-in `io` library and lose access to `io.stderr`, `io.stdin`, `io.stdout`.

**wrong:**
```teal
local io = require("cosmic.fd") -- hides io.stderr!
io.stderr:write("error\n") -- runtime error: attempt to index nil
```

**right:**
```teal
local fs = require("cosmic.fs") -- keep built-in io accessible
fs.write("out.txt", data)
io.stderr:write("error: " .. msg .. "\n") -- standard Lua io still works
```

cosmic.fd has no stderr/stdout/stdin handles — use Lua's `io.stderr` directly for stream output.

## 7. `arg[0]` is not the interpreter — use `arg[-1]` to re-invoke cosmic

when a script needs to spawn the cosmic binary itself (e.g. to run another
script as a child process), `arg[0]` is the script path as the runtime sees
it (`/zip/main.lua` for the embedded entry point), not the interpreter.
the interpreter path lives at `arg[-1]`, and because `arg` is typed
`{string}`, negative indices need `rawget` in strict mode.

**wrong:**
```teal
local child = require("cosmic.child")
local h = child.start({arg[0], "worker.tl"}) -- spawns /zip/main.lua: fails
```

**right:**
```teal
local child = require("cosmic.child")
local cosmic_bin = rawget(arg, -1) as string -- e.g. "./cosmic"
local h = child.start({cosmic_bin, "worker.tl"})
```

## 8. `print(f(...))` prints every return value

most cosmic functions return `(value, error)`. passing such a call directly
as the last argument to `print` (or any function) passes BOTH returns —
`print` renders the trailing `nil` as literal text, tab-separated. this
passes the type checker and only shows up in the output.

**wrong:**
```teal
print(json.encode(result))
-- prints: {"count":6}	nil
```

**right:**
```teal
local encoded, err = json.encode(result)
if err then
  io.stderr:write("encode failed: " .. err .. "\n")
  os.exit(1)
end
print(encoded)
```

(parenthesizing the call — `print((json.encode(result)))` — also truncates
to one value, but capturing lets you check the error.)

## 9. records, maps and arrays don't narrow through `if not x` — or `assert`

scalars (`string | nil`, `integer | nil`) narrow through an ordinary
truthiness guard. records, maps and arrays do not — below the guard the
value is still `T | nil`. **`assert(x, "msg")` is the same trap**: it
terminates control flow at runtime, but the checker still sees
`T | nil` on every line after it — do not expect the narrowing other
typed languages attach to assert. the errors either shape produces name
the un-narrowed type but not the cause: `cannot index key 'x' in
variable 'r' of type R | nil`, `expression in for loop does not return
an iterator`, `attempting ipairs on something that's not an array:
{T} | nil`.

**wrong:**
```teal
local db = sqlite.open(path) -- Database | nil
if not db then
  return nil, "open failed"
end
db:exec(sql) -- error: cannot index key 'exec' ... Database | nil
```

**right — branch with `is` and do the work inside the positive branch:**
```teal
if db is sqlite.Database then
  return run(db) -- run(db: sqlite.Database) receives it narrowed
end
return nil, "open failed"
```

**right — keep the guard, cast once immediately after it:**
```teal
if not db then
  return nil, "open failed"
end
local d = db as sqlite.Database -- cast: record union after guard
d:exec(sql)
```

(the same cast-after-guard works after an `assert(db, "open failed")`;
in tests and examples, `local db = check.must(sqlite.open(path))` does
guard and narrowing in one call, with no cast to justify.)

record fields don't narrow either, even scalar ones — copy the field to
a local and guard the local.

and one scalar caveat: a narrowed scalar still cannot be METHOD-called.
after `if not data then return end`, plain uses of `data` work, but
`data:gmatch(...)` fails with `cannot index key 'gmatch' in variable
'data' of type string | nil`. use the function form on the narrowed
value (`string.gmatch(data, ...)`), or branch with `if data is string
then ... end`, which narrows for every use. the full pattern set is in
`cosmic --docs guide.checking`.

## 10. a record other files use must be nested in the module's interface record

a standalone top-level `local record` is visible only inside its own
file. another file writing `store.Task` gets `unknown type store.Task` —
at every use site — even though the value-level API works fine. to
export a type, nest it inside the module's returned interface record.

**wrong** (`store.tl`):
```teal
local record Task -- file-local: importers cannot name it
  id: integer
  text: string
end

local record StoreModule
  add: function(path: string, text: string): Task | nil, string
end
```

**right:**
```teal
local record StoreModule
  record Task -- nested: importers write store.Task
    id: integer
    text: string
  end
  add: function(path: string, text: string): Task | nil, string
end
```

(a `type Task = Task` alias member inside the interface record also
works when the record must stay standalone for internal reasons — see
how `cosmic.fs` re-exports `Stat`.)

## 11. shadowing a Lua builtin

`--check types` warns on any shadowed declaration, including Lua's own
globals — a `local function load(...)` shadows the builtin `load()`,
`local type = ...` shadows `type()`. the warning
(`function shadows previous declaration of 'load'`) fails the strict
check because warnings are errors; rename yours (`load_data`,
`kind`, ...). the same trap at module level is gotcha #6's `io` example:
binding `require("cosmic.fd")` to a local named `io` hides `io.stderr`.

## 12. colon-call only works on the value's own record type

`db:exec(sql)` works because `exec` is declared on `sqlite.Database`
itself. a function YOUR module declares that merely takes such a value
as its first argument is not a method of that value — calling it with a
colon fails:

```teal
local record StoreModule
  add: function(db: sqlite.Database, name: string): boolean, string
end

db:add("alice") -- error: invalid key 'add' in record 'db' of type sqlite.Database
store.add(db, "alice") -- right: module function, dot-called, value first
```

to get colon-call ergonomics for your own type, declare your own record
with function fields taking `self` and construct values of it — see how
`cosmic.fd`'s `Handle` does it. mixing the two (module functions over a
foreign type) is the common, simpler shape; call them with a dot.

## 13. `local x = nil` means type nil, forever

a local initialized with `= nil` and NO type annotation is inferred as
the type `nil` — not "unknown yet", not `T | nil`. every later
assignment and use then fails, no guard helps, and neither error names
the declaration as the cause:

**wrong:**
```teal
local earliest = nil -- type: nil
for _, e in ipairs(entries) do
  if not earliest or e.timestamp < earliest then
    -- error: cannot use operator '<' for types integer and nil
    earliest = e.timestamp
    -- error: in assignment: got integer, expected nil
  end
end
```

**right — annotate the optional at the declaration:**
```teal
local earliest: integer | nil = nil
```

with the annotation, the running-min/max idiom above compiles as
written — scalars narrow through the `not earliest or ...` guard fine.

## 14. `os.exit` requires `integer | boolean`, not `number`

a `main` function declared to return `number` breaks `os.exit(main())`
with `got number, expected integer | boolean`.

**wrong:**
```teal
local function main(): number
  return 0
end
os.exit(main())
```

**right:**
```teal
local function main(): integer
  return 0
end
os.exit(main())
-- or convert at the call site: os.exit(math.tointeger(code) or 1)
```
