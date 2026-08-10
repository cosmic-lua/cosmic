# Teal Gotchas for Newcomers

common errors that trip up agents and developers new to Teal. each
entry shows the wrong pattern, the error it produces, and the fix.

entries are named by their heading slug — cite one as "the
`record-fields-dont-narrow` gotcha", never by position — so entries
can retire without a renumbering breaking references. an entry whose
trap became unreachable (a checker error, a lint at the declaration)
is deleted, not tombstoned: the checker's own message now carries the
fix.

## integer-vs-number

Teal distinguishes `integer` from `number`: string indices
(`string.sub`, `string.byte`, table lookups) require `integer`, and
arithmetic yields `number`. the `got number, expected integer` error
carries the fix as a hint — annotate the variable `: integer`, or
convert at the call site with `math.tointeger`.

```teal
local x = 2.0 -- a number from a computation

local n: integer = 5
local s = ("hello"):sub(n, n)
-- from a computation: convert first
local m = ("hello"):sub(math.tointeger(x) or 1, 5)
print(s, m)
```

(bindings that return integral values — exit statuses, fds, pids,
sizes — are annotated `integer` at the source of truth, so no
conversion dance is needed on that side.)

## any-from-json-decode

for the two common top-level shapes, skip `any` entirely:
`json.decode_object` returns `{string: any} | nil, string` and
`json.decode_array` returns `{any} | nil, string` — the checker sees a
concrete type with no cast, and input of the wrong shape is a real
error instead of a downstream indexing surprise.

```teal
local json = require("cosmic.json")

local input = '[{"name": "cosmic"}]'
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
trusted. a new cast needs its `-- cast: <reason>` justification (the
lint enforces it).

## nilable-arg

`arg` is typed `{string}`, so the checker will NOT catch a missing
argument for you: `arg[1]:upper()` type checks and then indexes nil at
RUNTIME when nobody passed one. Supply the default at the point of use
— the guard is the whole fix, and it is one `or` wide:

```teal
local name = (arg[1] or "default"):upper()
print(name)
```

inside `cosmic.main`, a usage guard is an early return, and the scalar
narrows through it for plain (non-method) uses:

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

the checker's `excess return values` error carries the fix as a hint:
capture multiple returns first — `local v, err = f(...)`. wrapping a
multi-return call inside another expression discards the extra returns.

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

## record-fields-dont-narrow

a guard on a plain variable narrows it: truthiness (`if r then`, `if
not r then return end`), `assert(r, "msg")`, `r and r.field`, and
`== nil` / `~= nil` comparisons all narrow `T | nil` for every `T` (the
carried tl patch, `3p/tl/tl_patch.tl`) — and `assert` narrows in
expression position too, so `local db = assert(sqlite.open(p))` is
`Database`, not `Database | nil`:

```teal
local sqlite = require("cosmic.sqlite")

local db = sqlite.open(":memory:") -- Database | nil
if not db then
  return nil, "open failed"
end
local _ok, _err = db:exec("CREATE TABLE t (x TEXT)") -- db is Database below
```

`~= nil` is exact, so it also narrows unions containing `boolean`,
where truthiness and `assert` deliberately do nothing (`false` is
falsy, so truthy does not mean "not nil" there).

what still does NOT narrow is a record FIELD, even a scalar one: after
`if o.sub then`, `o.sub` is still `Inner | nil` at the use. copy the
field to a local and guard the local:

```teal
local record Inner
  x: integer
end
local record Outer
  sub: Inner | nil
end
local o: Outer = {sub = {x = 1}}

local sub = o.sub -- Inner | nil
if sub then
  print(sub.x) -- narrowed; the field read would not be
end
```

(`is` narrowing also does not survive an early-exit guard — `if not (x
is Rec) then return end` does not narrow below it; write the plain
truthiness form instead. and a guard whose block ends in `error(...)`
rather than `return` does not narrow below itself either — the checker
cannot see that the block is terminal; use `assert` there.) the errors
these shapes produce name the
un-narrowed type but not the cause: `cannot index key 'x' in ... of
type Inner | nil`. the full pattern set is in
`cosmic --docs guide.checking`.

## exported-record-types

a standalone top-level `local record` is visible only inside its own
file. another file writing `store.Task` gets `unknown type store.Task` —
at every use site — even though the value-level API works fine. to
export a type, nest it inside the module's returned interface record.

nest it, and importers write `store.Task`:

```teal
local record StoreModule
  record Task -- nested: importers write store.Task
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

(a `type Task = Task` alias member inside the interface record also
works when the record must stay standalone for internal reasons — see
how `cosmic.fs` re-exports `Stat`.)

## colon-call

the checker's `invalid key 'add' in record 'db'` error carries the fix
as a hint: a function on your MODULE's record is dot-called with the
value first (`store.add(db, ...)`), never colon-called (`db:add(...)`).
colon-call works only for functions declared on the value's own record
type (like `db:exec` on `sqlite.Database`).

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
local _ok, _err = store.add(db, "alice") -- dot-called, value first
```

## gsub-replacement

`string.gsub`'s replacement is not plain text (`%1` splices a capture,
a lone `%` is a runtime error), so templating an untrusted value in
breaks on the first `%`. for literal text use `str.replace`
(cosmic.string) — literal on both sides, nothing to escape. the
`gsub-replacement` lint flags a non-literal replacement and
`cosmic --docs guide.lint` documents the deliberate-template escape.

```teal
local str = require("cosmic.string")
local template = "hello, {{name}}"
local user_name = "cosmic"
local page = str.replace(template, "{{name}}", user_name)
print(page)
```

## tuple-spread

Lua spreads every return of a call in the LAST argument position into
the argument list, and the checker counts the declared tuple — so
`table.insert(parts, str.partition(line, "="))` presents four arguments
(`partition` declares three returns) and fails with `wrong number of
arguments`. the error-site hint names the fix: parenthesize to
truncate to one value.

```teal
local str = require("cosmic.string")

local parts: {string} = {}
local line = "key=value"
table.insert(parts, (str.partition(line, "=")))
```

runtime behavior differs from the checker only when the extra returns
are `nil` (they collapse away), which is why such a site can look
correct until `--check types` runs.

`check.must` is NOT in this family: it declares one return (#1064), so
`table.insert(parts, check.must(chunk))` and
`return check.must(sqlite.open(":memory:"))` both check clean with no
parentheses. Only a genuinely multi-value function — an infallible
tuple like `partition`, or a `cosmo.*` binding — spreads here, because
a fallible cosmic return has two slots and no more.
