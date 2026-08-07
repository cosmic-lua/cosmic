# Teal Gotchas for Newcomers

common errors that trip up agents and developers new to Teal. each entry shows the wrong pattern, the error it produces, and the fix.

## 1. integer vs number

Teal distinguishes `integer` from `number`: string indices
(`string.sub`, `string.byte`, table lookups) require `integer`, and
arithmetic yields `number`. the `got number, expected integer` error
carries the fix as a hint — annotate the variable `: integer`, or
convert at the call site with `math.tointeger`.

```teal
local n: integer = 5
local s = ("hello"):sub(n, n)
-- from a computation: convert first
local m = ("hello"):sub(math.tointeger(x) or 1, 5)
```

(bindings that return integral values — exit statuses, fds, pids,
sizes — are annotated `integer` at the source of truth, so no
conversion dance is needed on that side.)

## 2. traversing `any` from json.decode

for the two common top-level shapes, skip `any` entirely:
`json.decode_object` returns `{string: any} | nil, string` and
`json.decode_array` returns `{any} | nil, string` — the checker sees a
concrete type with no cast, and input of the wrong shape is a real
error instead of a downstream indexing surprise.

```teal
local items = json.decode_array(input)
if items is {any} then
  for _, raw in ipairs(items) do
    if raw is {string: any} then
      print(raw["name"] as string)
    end
  end
end
```

`json.decode` still returns `any`, for the genuinely-dynamic case: you
cannot index or iterate `any` directly — narrow with `is` where the
shape is uncertain (as with the nested values above), or cast
(`local obj = json.decode(input) as {string: any}`) when the shape is
trusted. new casts count against the cast ratchet (`_build/casts.txt`).

## 3. `arg` elements are `string | nil`

the global `arg` table has type `{string | nil}`: accessing `arg[1]`
without a guard may give you `nil`, a type error where a `string` is
expected. (a missing argument is `nil` at runtime either way — guard
before use.)

**wrong:**
```teal
local name = arg[1]:upper() -- error: cannot index nil
```

**right:**
```teal
local name = (arg[1] or "default"):upper()
```

inside `cosmic.main`, a usage guard is an early return, and the scalar
narrows through it for plain (non-method) uses:

```teal
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

## 4. multi-return capture

the checker's `excess return values` error carries the fix as a hint:
capture multiple returns first — `local v, err = f(...)`. wrapping a
multi-return call inside another expression discards the extra returns.

```teal
local rows, err = db:query("SELECT * FROM t")
if not rows then
  error("query failed: " .. tostring(err))
end
for row in rows do
  print(row.id)
end
```

## 5. retired — moved to guide.modules

how `require` resolves local module paths is information, not a trap;
it now lives in `cosmic --docs guide.modules`.

## 6. retired — the checker prevents it

binding a module to a local that shadows a Lua builtin
(`local io = require("cosmic.fd")`) is a `--check types` error today
(`variable shadows previous declaration of 'io'`, warnings are errors),
so the runtime surprise this entry described is unreachable. rename the
local (`fd`, `fs`, ...); Lua's `io.stderr` stays available.

## 7. retired — `proc.interpreter()` is the one-call answer

`arg[0]` is the script path as the runtime sees it (`/zip/main.lua` in
a packed binary), not the interpreter. to re-invoke cosmic, call
`require("cosmic.proc").interpreter()` — typed, resolved, cached; the
self-reinvocation recipe in `cosmic --docs guide.recipes` shows the
whole shape.

## 8. retired — the checker flags discarded errors

most cosmic functions return `(value, error)`, and the strict checker
(`--check types`, and the build's strict compile) now flags both ways
the error used to vanish: a fallible call standing as a bare statement
(`fs.write(path, data)` on its own line), and a fallible call as the
final argument of `print` and friends (which rendered the error as a
literal `nil`). capture the returns — `local v, err = f(...)`, or
`local _ok, _err = f(...)` for deliberate fire-and-forget — or wrap in
`assert`/`check.must` in tests and examples. the details are in
`cosmic --docs guide.checking`.

## 9. record fields don't narrow — copy the field to a local

a guard on a plain variable narrows it: truthiness (`if r then`, `if
not r then return end`), `assert(r, "msg")`, and `== nil` / `~= nil`
comparisons all narrow `T | nil` for every `T` (the carried tl patch,
`3p/tl/tl_patch.tl`):

```teal
local db = sqlite.open(path) -- Database | nil
if not db then
  return nil, "open failed"
end
db:exec(sql) -- db is Database below the guard
```

`~= nil` is exact, so it also narrows unions containing `boolean`,
where truthiness and `assert` deliberately do nothing (`false` is
falsy, so truthy does not mean "not nil" there).

what still does NOT narrow is a record FIELD, even a scalar one: after
`if o.sub then`, `o.sub` is still `Inner | nil` at the use. copy the
field to a local and guard the local:

```teal
local sub = o.sub -- Inner | nil
if sub then
  print(sub.x) -- narrowed; the field read would not be
end
```

(`is` narrowing also does not survive an early-exit guard — `if not (x
is Rec) then return end` does not narrow below it; write the plain
truthiness form instead.) the errors these shapes produce name the
un-narrowed type but not the cause: `cannot index key 'x' in ... of
type Inner | nil`. the full pattern set is in
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

## 11. retired — the checker prevents it

shadowing any declaration, including Lua builtins (`local function
load(...)`, `local type = ...`), is a `--check types` error today
(warnings are errors). the error names the shadowed declaration; rename
yours (`load_data`, `kind`, ...).

## 12. colon-call only works on the value's own record type

the checker's `invalid key 'add' in record 'db'` error carries the fix
as a hint: a function on your MODULE's record is dot-called with the
value first (`store.add(db, ...)`), never colon-called (`db:add(...)`).
colon-call works only for functions declared on the value's own record
type (like `db:exec` on `sqlite.Database`).

```teal
db:add("alice") -- error: invalid key 'add' in record 'db' of type sqlite.Database
store.add(db, "alice") -- right: module function, dot-called, value first
```

## 13. retired — the lint catches it at the declaration

a local initialized with `= nil` and no type annotation is inferred as
the type `nil` — forever. the `nil-declaration` lint now flags the
declaration itself with the fix (`local x: integer | nil = nil`), so
the far-away assignment errors this entry used to explain are never
reached. with the annotation, the running-min/max idiom compiles as
written — scalars narrow through the `not earliest or ...` guard fine.

## 14. retired — the taught path never calls `os.exit`

`cosmic.main(fn)` (the entry-point shape the quickstart teaches) does
the exit itself and accepts any numeric return, so this trap no longer
appears on the taught path. if you call `os.exit` yourself, it requires
`integer | boolean`, not `number` — convert at the call site
(`os.exit(math.tointeger(code) or 1)`); the error-site hint names the
same fix.

## 15. `gsub`'s replacement string interprets `%` — use `str.replace` for literal text

`string.gsub`'s replacement is not plain text (`%1` splices a capture,
a lone `%` is a runtime error), so templating an untrusted value in
breaks on the first `%`. for literal text use `str.replace`
(cosmic.string) — literal on both sides, nothing to escape. the
`gsub-replacement` lint flags a non-literal replacement and
`cosmic --docs guide.lint` documents the deliberate-template escape.

```teal
local str = require("cosmic.string")
local page = str.replace(template, "{{name}}", user_name)
```
