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
one PHYSICAL line, however many casts that line holds — never a whole
statement: a call spread over five lines with a cast on each needs five
comments, not one above the call.

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

the multi-line shape is where the per-line rule bites, and it is the
common one — a `{string: any}` row widened field by field into a typed
record:

```teal
local record Note
  id: integer
  title: string
end

local row: {string: any} = {id = 1, title = "first"}
local note: Note = {
  id = row.id as integer, -- cast: from any (sqlite row)
  title = row.title as string, -- cast: from any (sqlite row)
}
print(note.id, note.title)
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
`test_*` in a `*_test.tl` is treated as a test that must call itself.
name your helpers something else (`make_fixture`, `db_path_for`, ...) —
an uncalled helper that happens to start with `test_` is flagged.
`Example_*` functions are exempt (the example runner calls them), and
the rule does not apply outside `*_test.tl` files.

## cosmo-require

tests and examples must use the typed `cosmic.*` wrappers, never the
raw `cosmo.*` C bindings:

```
cosmic/foo_test.tl:3: require("cosmo...") forbidden in tests/examples; use cosmic.* wrappers
```

library internals implementing wrappers are the one place
`require("cosmo")` is expected; everywhere else, the wrapper exists and
is the API (see `cosmic --docs guide.modules`).

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
