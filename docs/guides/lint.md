# Lint Rules

`cosmic --make lint` (and its per-file form `cosmic --check lint <file>`)
runs the style gate. every rule it can fire is enumerated here, with the
failure it produces and the fix — so the first time you meet a rule is
not the moment you have to reverse-engineer it.

lint reads BYTES, deliberately: the project walk feeds it every file the
model sees, not just `.tl`/`.lua` sources — a `.md`, a `.mk`, a vendored
payload are all held to the same standard. `testdata/` is the one
exempt kind (fixtures are often deliberately wrong), and a file that
should not be judged at all is listed in `.cosmicignore` (one glob per
line; see `cosmic --docs guide.make`).

## file-length

every file must be ≤500 lines. no exceptions for source: the fix for a
long `.tl` file is to split it. `.d.tl` type-declaration files are
exempt (they describe C binding interfaces and cannot be split under
Teal's record system).

```
db/query.tl:501:1: file-length: db/query.tl has 512 lines (limit: 500)
```

a length failure on a NON-source file (a stray binary, a data file) is
the walk telling you it swept in something you did not mean to gate —
the fix is `.cosmicignore`, not splitting the file.

## cast-justify

every `as` cast is an unchecked hole in the type system, so each one
must say why: a trailing `-- cast: <reason>` on the same line, or on the
line directly above when 90 columns will not fit it. one comment covers
the whole line, however many casts the line holds.

```teal
local check = require("cosmic.check")
local json = require("cosmic.json")
local sqlite = require("cosmic.sqlite")

local db: sqlite.Database | nil = check.must(sqlite.open(":memory:"))
local input = "{}"

local d = db as sqlite.Database -- cast: record union after guard

-- cast: from any (json.decode result)
local obj = json.decode(input) as {string: any}
print(d, obj)
```

write the actual reason (`from any`, `userdata boundary`, `record union
after guard`, `tuple element`, ...). a cast you cannot justify is one to
remove — prefer `is` narrowing where the code branches, or `check.must`
in tests and examples. the narrowing patterns are in
`cosmic --docs guide.checking`.

this rule fires at lint time only: `--check types`, `--make build`, and
`--make test` all accept an unjustified cast, so the first complaint
comes from `--make lint`/`--make ci` — or from `--check lint <file>`,
the same gate early. it applies to every file the walk gates, test
files included: a cast added to satisfy the checker in a `*_test.tl`
needs its `-- cast:` reason like any other.

## assert-justify

the same convention, for the other escape hatch. library code must never
throw, and `assert` throws — so a bare `assert` in a `cosmic/**` module is
a doctrine violation unless D23's licence applies: the `| nil` being
asserted away must be unreachable *for the arguments that call passes*.
`cosmic.time.now()` reads `unix.clock_gettime(unix.CLOCK_REALTIME)`,
whose first slot can only be nil for a clock id the kernel rejects — not
for either constant that module passes.

only a reader can check that argument, so the assert has to state it, as
a trailing `-- assert: <why the nil cannot occur>` or one on the line
directly above:

```text
local secs = assert(unix.clock_gettime(unix.CLOCK_REALTIME))
```

```text
-- assert: CLOCK_REALTIME is always a valid clock id
local secs = assert(unix.clock_gettime(unix.CLOCK_REALTIME))
```

write the argument, not a restatement of the rule — "cannot be nil" says
nothing a reader can check. if the nil IS reachable, the assert is the
wrong shape entirely: return it as `nil, err` and let the caller decide.

the rule governs `cosmic/**` library source only. `*_test.tl` and
`*_example.tl` assert freely — the tree's test pattern is built on
`assert`, and `check.must` is the assertion tests reach for — and the
toolchain trees (`_cli/`, `_make/`, `_tool/`, `_build/`, `cmd/`) are not
library code. one comment covers the whole line, however many asserts the
line holds, exactly as with `-- cast:`.

the walk is token-exact, which is what makes the rule usable: `cosmic/**`
holds 23 occurrences of `assert(` today and every one is inside a doc
comment or a string constant — including the `assert(loadfile(...))` in
`cosmic/embed/init.tl`, which is a line of the entry wrapper that module
WRITES rather than runs. a grep-based rule would flag all 23.

## call-after-define

in a `*_test.tl` file, a top-level `local function test_*()` must be
called on the line after its `end`, so a failing run names the function
that failed rather than just the file:

```teal
local json = require("cosmic.json")

local function test_decode()
  assert(json.decode("1") == 1)
end
test_decode()
```

the rule keys on the `test_` name prefix: any top-level function named
`test_*` in a `*_test.tl` is a test. name your helpers something else
(`make_fixture`, `db_path_for`, ...). `Example_*` functions are exempt
(the example runner calls them), and the rule does not apply outside
`*_test.tl` files.

a file picks ONE mode (D29): **legacy** — every test called on the line
after its `end`, as above — or **runner** — no test self-calls and no
test name is referenced anywhere else in the file; the toolchain runs
what discovery finds. both lint clean. a MIX is the one shape the rule
refuses, naming the uncalled tests: under legacy semantics the uncalled
half would silently never run. a late call block at the bottom of the
file is not runner mode either — it keeps the old diagnostic, because
the runner tail would run those tests a second time. the shared walk
lives in `_tool/discover.tl`.

## cosmo-require

tests and examples must use the typed `cosmic.*` wrappers, never the
raw `cosmo.*` C bindings:

```
cosmic/foo_test.tl:3: require("cosmo...") forbidden in tests/examples; use cosmic.* wrappers
```

library internals implementing wrappers are the one place
`require("cosmo")` is expected; everywhere else, the wrapper exists and
is the API (see `cosmic --docs guide.modules`).

## fallible-returns

a function that can FAIL returns at most two values, and slot 2 is its
error. it can fail when its first declared return admits nil — `T | nil`,
or `any`, which admits everything — and then a third slot is unreachable
from the two ways anyone actually calls it:

```
db/query.tl:31: fallible-returns: a fallible return (slot 1 admits nil) declares 3 slots; ...
```

```teal
local record Row
  id: integer
  name: string
end

-- the error is in slot 3, so `local v, err = first(db)` binds a boolean
-- to err, and check.must(first(db)) feeds that boolean to must's `err`
-- local function first(db: string): Row | nil, boolean, string

--- carry the extras in the value's record instead
local record Found
  row: Row
  --- true when a row matched; a nil row with found = false is "absent"
  found: boolean
end
local function first(_db: string): Found | nil, string
  return {row = {id = 1, name = "a"}, found = true}
end
local found, err = first("db")
print(found, err)
```

an INFALLIBLE tuple is untouched: `string.partition` returns
`string, string, string` and no slot of it could be an error, so the
rule has nothing to say about it. the discriminator is nil in slot 1,
never a guess about what the slots mean.

there is no escape hatch, and none is needed. a `cosmo.*` binding's
tuple IS decided in C — but it is already declared, once, in the
generated `.d.tl` files, which describe C interfaces and which lint
exempts by position. so when you need to name a binding's shape, refer
to the generated type rather than retyping it:

- `cosmic.re`'s `Regex` IS `cosmo.re`'s, not a copy of it
- cast the ARGUMENT that needs widening, not the whole binding, and no
  return list has to be restated to give the cast a target
- declare `any...` when the arity genuinely is not yours to know — a
  varargs return is one slot, and honest about it

the rule shipped with a `-- returns: <reason>` comment marker. every
site that used one turned out to be a cosmic-side restatement of a
declaration that already existed, and two had already drifted from the
binding they copied. the marker is gone.

the rule exists because the two
call shapes everyone writes — `local v, err = f()` and
`check.must(f())` — can only see two slots, so anything past the second
is information the caller has to be TOLD about, one call site at a time.

## find-needle

`s:find(x)` treats `x` as a Lua pattern, so a `-`, `.`, `(` or `%` in it
silently changes what matches — and the call still returns, just about
the wrong thing. when the needle is not a string literal, say which you
meant: `, 1, true` for a plain substring, `, 1, false` to mean the
pattern.

```teal
local s = "a-b"
local path = "a-b"
local pat = "%a+"

s:find(path, 1, true) -- substring: a dash in path stays a dash
s:find(pat, 1, false) -- pattern, on purpose
s:find("%d+") -- literals are exempt: this reads as a pattern
```

there is no plain flag on `match`/`gmatch`/`gsub`, so a variable needle
there is a pattern by construction; escape it if it isn't one.

## gsub-replacement

`gsub`'s replacement side is magic too: `%1`–`%9` splice in captures,
`%0` the whole match, and a lone `%` before anything else is a runtime
error — so templating an untrusted value in corrupts output or crashes
on the first `%`. when the replacement is not a string literal, say
what you mean:

```teal
local str = require("cosmic.string")

local template = "hello, {{name}}"
local user_name = "cosmic"
local pat = "{{name}}"

str.replace(template, "{{name}}", user_name) -- literal on BOTH sides
-- deliberate template: escape, and say so
local safe = user_name:gsub("%%", "%%%%")
local page = template:gsub(pat, safe) -- gsub: safe is %%-escaped above
print(page)
```

literals are exempt (a literal `"%1"` reads as deliberate splicing), as
are function and table replacements — those forms do not interpolate.
the marker is `-- gsub: <reason>`, trailing or on the line above, same
positions as `-- cast:`.

## nil-declaration

a local initialized to `nil` with no type annotation is inferred as the
type `nil` — not "unknown yet" — so every later assignment fails, far
from the cause. the rule fires at the declaration, where the fix is:

```teal
local earliest: integer | nil = nil -- the honest optional
print(earliest)
```

an all-nil multi declaration (`local a, b = nil, nil`) is flagged too;
a mixed right-hand side is left to the checker's error-site hint.

## return-assert

`assert` is declared with ONE return, which is what lets
`local db = assert(open(path))` yield a plain `Database` instead of a
union. Lua's `assert` actually returns ALL of its arguments, so in
return position that declaration is a lie:

```text
local function join(a: string, b: string): string
  return assert(joined, "join: every argument was nil")  -- two values
end
```

the checker reads one value; at runtime the function returns two, and
the second one appears wherever the call sits in a multiple-value
position — `table.insert(out, join(dir, entry))` becomes the
three-argument `table.insert` and fails with an error naming neither
function. assert as a statement keeps the arity honest:

```text
assert(joined, "join: every argument was nil")
return joined
```

only the trapping shape fires: two or more arguments, and the call is
the last expression of the return list. `return assert(v)` returns one
value, `return assert(v, m), other` truncates the call to one, and
`return (assert(v, m))` truncates it too — none of those is flagged.
`check.must` is a real one-value function and is never flagged.

## visibility

a module under `cosmic/` may only be required from outside `cosmic/`
through its public parent: `require("cosmic.fs")` is API,
`require("cosmic.fs.types")` from outside is reaching into a shard, and
`require("cosmic._anything")` from outside is reaching into an
internal. inside `cosmic/`, shards require each other freely — that is
what shards are for.

## running one rule's worth of output

```bash
cosmic --check lint file.tl     # one file, all rules
cosmic --make lint              # the whole project
cosmic --make lint db/          # …or one subtree
```

each diagnostic is `file:line: rule: message`, and the gate ends in a
verdict line (`lint: PASS (12 files)`).
