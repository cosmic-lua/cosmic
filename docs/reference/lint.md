# Lint rules

every rule `cosmic --check lint` and `cosmic --make lint` can fire, with what it
fires on, the diagnostic it prints, the files it covers, and the fix.

## What lint reads

lint reads bytes. the project walk feeds it every file the project model sees,
not only `.tl` and `.lua` sources: a `.md`, a `.mk`, a `.yml` and a vendored
payload are held to the same rules. `testdata/` is the one exempt kind. a file
that should not be judged is listed in `.cosmicignore` at the project root.

`.cosmicignore` holds one glob per line. a line starting with `#` is a comment.
a trailing `/` is dropped, so `build/` and `build` mean the same thing. a glob
matches either the whole relative path or the bare name, so `vendor`,
`3p/vendor` and `*.log` all behave the way they read.

the rules a file meets depend on its name:

| file | rules |
|---|---|
| every file | file-length |
| `*.tl` | every rule below except doc-citation |
| `*.md` | file-length, doc-citation |
| `*.d.tl` | none |

`.d.tl` files describe C binding interfaces and are exempt from every rule. an
empty file passes. `--check types`, `--make build` and `--make test` run none of
these rules. the first diagnostic comes from `--check lint <file>`,
`--make lint` or `--make ci`.

## Justification comments

five rules accept a marker comment: `-- cast:`, `-- assert:`, `-- throws:`,
`-- exits:` and `-- gsub:`. the same four facts hold for each:

- the comment is `-- <marker>: <reason>`, trailing on the site's line, or alone
  on the line directly above when 90 columns will not fit it.
- the reason is required. a bare `-- cast:` justifies nothing.
- one comment covers the whole line, however many sites the line holds.
- the marker word states what the site does. an `-- exits:` on an `error(`
  line does not license it.

## file-length

fires on a file with more than 500 lines.

```text
db/query.tl:501:1: file-length: db/query.tl has 512 lines (limit: 500)
```

on a file that is not Teal or Lua source the message adds that lint gates every
file the project walk sees, and names `.cosmicignore` as the fix. a file
holding a NUL byte is called a binary file.

scope: every file the walk sees. `.d.tl` files are exempt: they describe C
binding interfaces that Teal's record system cannot split.

fix: split a source file. for a data file or a binary the walk swept in, list it
in `.cosmicignore`.

## cast-justify

fires on an `as` cast with no `-- cast: <reason>` on its line or the line above.

```text
db/query.tl:31:1: cast-justify: db/query.tl:31: `as` cast without justification:
prefer `is` narrowing or check.must (see `cosmic --docs howto.narrow-nil`); a
deliberate cast takes a trailing `-- cast: <reason>` (or on the line above)
```

scope: every `.tl` file the walk gates, test files included.

fix: write the actual reason. `from any`, `userdata boundary`, `record union
after guard` and `tuple element` are reasons. a cast with no reason is one to
remove: use `is` narrowing where the code branches, or `check.must` in tests
and examples. `cosmic --docs howto.narrow-nil` has the steps.

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

## assert-justify

fires on an `assert(` call in library source with no
`-- assert: <why the nil cannot occur>` on its line or the line above.

```text
cosmic/time.tl:40:10: assert-justify: cosmic/time.tl:40: a library `assert` throws,
and throwing from `cosmic/**` needs D23's licence: the `| nil` must be
unreachable for the arguments THIS call passes. Say which, in a trailing
`-- assert: <why the nil cannot occur>` (or on the line above); if the nil IS
reachable, return it as `nil, err` instead (see `cosmic --docs reference.lint`)
```

scope: `cosmic/**` library source only. `*_test.tl` and `*_example.tl` assert
freely. the toolchain trees (`_cli/`, `_make/`, `_tool/`, `_build/`, `cmd/`)
are not library code. the walk is token-exact: an `assert(` inside a comment or
a string constant never counts.

the licence: a library module may assert a `cosmo.*` binding return whose
declared `| nil` is unreachable for the arguments that call passes.
`cosmic.time.now()` reads `unix.clock_gettime(unix.CLOCK_REALTIME)`. its first
slot is nil only for a clock id the kernel rejects, and never for the constant
this module passes.

fix: state the argument a reader can check, on the line or the line above.

```text
-- assert: CLOCK_REALTIME is always a valid clock id
local secs = assert(unix.clock_gettime(unix.CLOCK_REALTIME))
```

"cannot be nil" restates the rule and says nothing a reader can check. if the
nil is reachable, the assert is the wrong shape: return `nil, err` and let the
caller decide.

## throw-justify and exit-justify

throw-justify fires on an `error(` call in library source with no
`-- throws: <why>`. exit-justify fires on an `os.exit(` or `unix.exit(` call
with no `-- exits: <why>`.

```text
cosmic/searcher.tl:88:3: throw-justify: cosmic/searcher.tl:88: a library `error`
needs D30's licence: no caller may be able to receive the value — a
require/loader protocol, a process boundary, or a typed contract violated past
the checker. Say which, in a trailing `-- throws: <why>` (or on the line above);
if a caller COULD receive it, return `nil, err` instead (see `cosmic --docs
reference.lint`)
```

the exit-justify message is the same text with `exit` and `-- exits: <why>`.

scope: the scope of assert-justify. two modules are exempt at the file level:
`cosmic/check.tl`, whose assertions and exits are its contract, and
`cosmic/rand.tl`, whose CSPRNG throws on failure. the walk is token-exact: a
quoted `error(` never counts, and the exit rule reads the receiver, so a
`proc.exit(` on some other record is not a process exit.

a library module may throw or exit only where no caller could receive the
value. that is three shapes:

- a Lua protocol whose error channel is the throw: a package searcher, a
  `coroutine.wrap` shim, a require-time probe for a hard dependency.
- a process boundary: a child after `fork` whose setup or `exec` failed, or an
  entry helper that turns a main function's return into the exit status.
- an infallible-by-type contract violated past the checker, such as an enum
  value smuggled through a cast.

fix: state which shape the site is.

```text
error("error loading module '" .. name .. "': " .. tostring(lerr), 0)
-- the line above carries: -- throws: package-searcher protocol; ...
os.exit(127) -- exits: forked child; the error is on the parent's pipe
```

if a caller could receive the value, the site is the wrong shape: return
`nil, err` instead.

## call-after-define

a `*_test.tl` file is in one of two modes. in runner mode no top-level
`local function test_*` is referenced again in the file. the toolchain discovers
every case by name and a tail appended at the compile seam calls each one in
source order. in legacy mode every test calls itself on the line after its own
`end`.

the rule fires on a mix: a `test_*` function that is not called right after its
`end`, in a file that is not runner mode. a call block at the bottom of the file
is not runner mode, and keeps this diagnostic.

```text
db/query_test.tl:11:1: call-after-define: db/query_test.tl:11: 'test_b' is not
called immediately after its definition, and the file is not runner mode either.
A file picks ONE mode (D29): call every test on the line after its `end`, or
call none of them anywhere
```

scope: `*_test.tl` files. the rule keys on the `test_` name prefix, so any
top-level function named `test_*` is a test. `Example_*` functions are exempt.

fix: write new files in runner mode. name helpers something other than `test_*`
(`make_fixture`, `db_path_for`). in a legacy file, call each test on the line
after its `end`:

```teal
local json = require("cosmic.json")

local function test_decode()
  assert(json.decode("1") == 1)
end
test_decode()
```

## cosmo-require

fires on `require("cosmo...")` in a test or example.

```text
cosmic/foo_test.tl:2:14: cosmo-require: cosmic/foo_test.tl:2: require("cosmo...")
forbidden in tests/examples; use cosmic.* wrappers
```

scope: `*_test.tl` and `*_example.tl`. a few tests whose fixture strings quote
the literal are allowlisted by name in `_cli/lint.tl`.

fix: require the `cosmic.*` wrapper. library internals implementing a wrapper
are the one place `require("cosmo")` belongs. `cosmic --docs <module>` names
the wrapper for each binding.

## fallible-returns

fires on a declared return list with more than two slots whose first slot
admits nil: `T | nil`, or `any`, which admits everything.

```text
db/query.tl:5:7: fallible-returns: db/query.tl:5: a fallible return (slot 1
admits nil) declares 3 slots; a caller writing `local v, err = f()` cannot reach
past slot 2, and check.must feeds slot 2 to its `err` parameter — carry the
extras in the value's record. A cosmo binding's own tuple is already declared
in the generated .d.tl: name that type rather than retyping its shape (see
`cosmic --docs reference.lint`)
```

scope: every `.tl` file. an infallible tuple is untouched: `string.partition`
returns `string, string, string` and no slot of it can be an error. the
discriminator is nil in slot 1, never a guess about what the slots mean.

fix: carry the extras on the value's record.

```teal
local record Row
  id: integer
  name: string
end

-- refused: local function first(db: string): Row | nil, boolean, string
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

there is no escape-hatch comment. a `cosmo.*` binding's tuple is decided in C
and declared once, in the generated `.d.tl` files, which lint exempts. refer to
the generated type instead of retyping it:

- `cosmic.re`'s `Regex` is `cosmo.re`'s type, not a copy of it.
- cast the argument that needs widening, not the whole binding. no return list
  has to be restated to give the cast a target.
- declare `any...` when the arity is not yours to know. a varargs return is one
  slot.

## find-needle

fires on `find` with a needle that is not a string literal and no plain flag.
`s:find(x)` treats `x` as a Lua pattern, so a `-`, `.`, `(` or `%` in it
changes what matches, and the call still returns.

```text
db/query.tl:8:1: find-needle: db/query.tl:8: `find` with a non-literal needle is
a PATTERN, so a `-`, `.` or `%` in it silently changes the match: pass `, 1,
true` for a substring, or `, 1, false` to mean the pattern
```

scope: every `.tl` file. a literal needle is exempt.

fix: say which you meant. `, 1, true` is a plain substring; `, 1, false` is the
pattern, on purpose.

```teal
local s = "a-b"
local path = "a-b"
local pat = "%a+"

s:find(path, 1, true) -- substring: a dash in path stays a dash
s:find(pat, 1, false) -- pattern, on purpose
s:find("%d+") -- literals are exempt: this reads as a pattern
```

`match`, `gmatch` and `gsub` have no plain flag, so a variable needle there is
a pattern by construction. escape it if it is not one.

## gsub-replacement

fires on `gsub` with a replacement that is not a string literal, a function or
a table, and no `-- gsub: <reason>`. the replacement side interpolates: `%1` to
`%9` splice in captures, `%0` the whole match, and a lone `%` before anything
else is a runtime error.

```text
db/query.tl:23:1: gsub-replacement: db/query.tl:23: a non-literal gsub
replacement interpolates % — for literal text use str.replace (cosmic.string);
a deliberate template takes an escape (value:gsub("%%", "%%%%")) and a trailing
`-- gsub: <reason>` (or on the line above)
```

scope: every `.tl` file. a literal replacement is exempt, because a literal
`"%1"` reads as deliberate splicing. function and table replacements are exempt,
because those forms do not interpolate.

fix: for literal text use `str.replace` from `cosmic.string`. for a deliberate
template, escape the value and say so.

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

## nil-declaration

fires on a local initialized to `nil` with no type annotation. the checker
infers the type `nil`, not "unknown yet", so every later assignment fails far
from the cause. an all-nil multi declaration (`local a, b = nil, nil`) fires
too. a mixed right-hand side is left to the checker's error-site hint.

```text
db/query.tl:3:1: nil-declaration: db/query.tl:3: a local initialized to nil with
no type annotation has type nil FOREVER — every later assignment fails;
annotate the optional: `local x: T | nil = nil`
```

scope: every `.tl` file.

fix: annotate the optional.

```teal
local earliest: integer | nil = nil -- the honest optional
print(earliest)
```

## return-assert

fires on `assert` with two or more arguments as the last expression of a return
list. `assert` is declared with one return, which is what lets
`local db = assert(open(path))` yield a plain `Database`. Lua's `assert` returns
all of its arguments, so in return position the declaration is wrong: the
checker reads one value and the function returns two. the second value appears
wherever the call sits in a multiple-value position.
`table.insert(out, join(dir, entry))` becomes the three-argument
`table.insert` and fails with an error naming neither function.

```text
db/query.tl:13:10: return-assert: db/query.tl:13: the carried tl patch declares
one return for `assert`, so the checker reads this as one value — but Lua's
assert returns ALL of its arguments, so this function is two-valued at runtime
and a caller's last-argument position expands both. Write the assert as a
statement and return the local (see `cosmic --docs reference.lint`)
```

scope: every `.tl` file. only the trapping shape fires. `return assert(v)`
returns one value, `return assert(v, m), other` truncates the call to one, and
`return (assert(v, m))` truncates it too. `check.must` is a real one-value
function and never fires.

fix: assert as a statement, then return the local.

```text
return assert(joined, "join: every argument was nil") -- refused

assert(joined, "join: every argument was nil") -- accepted
return joined
```

## reads-declaration

fires on an `fs.glob(` call in a test file that has no `--- reads:` header. the
build finds a test's inputs by a static scan of that header and cannot see what
a glob enumerates at runtime, so the test's cached PASS never re-runs when
those files change.

```text
db/query_test.tl:3:9: reads-declaration: db/query_test.tl:3: fs.glob()
enumerates files with no '--- reads:' declaration; a static import scan can't
see what it finds at runtime, so this test's cached PASS never re-runs when
those files change — add '--- reads: <dir>' naming what the glob covers (see
_make/imports.tl)
```

scope: `*_test.tl` files. only `fs.glob` is covered. a test whose globs read
only a fixture it builds under `TEST_TMPDIR` is allowlisted by name in
`_cli/reads_lint.tl`.

fix: add a `--- reads: <dir>` header line naming what the glob covers.

## visibility

fires on a `require` from outside `cosmic/` that reaches a cosmic-internal
module: a shard such as `cosmic.fs.types`, or an internal such as
`cosmic._anything`. a module is public exactly when it is `cosmic.<name>` with
no `_`.

```text
db/use.tl:1:15: visibility: db/use.tl:1: require("cosmic.fs.types") reaches a
cosmic-internal shard from outside cosmic/; use the public parent module (which
re-exports what outside callers need)
```

scope: every `.tl` file outside `cosmic/`. files inside `cosmic/` require
shards freely. `*_gen.tl` generators are exempt, because a generator runs under
the current binary before the tree rebuilds.

fix: require the public parent. `require("cosmic.fs")` is API, and it
re-exports what outside callers need.

## doc-citation

fires on a markdown citation of the tree by `path:line` that nothing verifies,
or that names a file or line that is not there. two citation forms exist, and
both are checked for the path.

the inline form is a whole backticked span that is nothing but a path and a
line, or a line range. it pins a position and quotes nothing, so the most the
gate can tell is that the file is that long. in a live document the form is
refused:

```text
docs/demo.md:3:2: doc-citation: docs/demo.md:3: inline citation
`_perf/run.tl:163` pins a line nothing verifies — this check can only tell
that _perf/run.tl is that long. Quote it as a fenced citation (a
`-- <path>:<line>` comment as the code block's first line, then the line
itself, whose text is compared), or drop the `:<line>` and name the symbol in
prose. A document describing a past commit says so with a `Measured against `
line.
```

the fenced form is a `-- path:line` comment on a code block's first line,
followed by the line itself. that block pins text, so the gate opens the source
and compares the quoted line with the cited one, trimmed at both ends.

```text
-- docs/reference/lint.md:1
# Lint rules
```

a path that names no file fails in either form. a line past the end of the
file fails. a quoted line that differs from the source fails, and the message
shows the document's line and the source's line side by side.

a document describing a past commit is a snapshot. it declares that in a line
of its own, outside any code fence:

```text
Measured against `40776231` on 2026-08-28.
```

in a snapshot the positions and quotes are not judged, because there is no
`git` in the lint gate. the paths are still checked.

scope: every `.md` file the walk sees. a citation into `o/` is skipped, because
those files are generated.

fix: quote the line as a fenced citation, or drop the `:<line>` and name the
symbol in prose. prefer the symbol when the sentence points at code instead of
quoting it.

## Commands

```bash
cosmic --check lint file.tl     # one file, all rules
cosmic --make lint              # the whole project
cosmic --make lint db/          # one subtree
```

## Diagnostic format

each diagnostic is one line, `file:line:col: rule: message`, followed by the
offending source line indented under `    | `. file-length prints no source
line. a clean file prints `Style check passed: <file>`. `--make lint` ends in a
verdict line: `lint: PASS (12 files)`, or `lint: FAIL (1 of 12 files)`.
