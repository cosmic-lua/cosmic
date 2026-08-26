# from-any casts

Every `as` cast in this tree carries a `-- cast: <reason>`
justification, and `from any` is one of those reasons — the shape that
stands furthest between the tree and G3's zero-cast win condition,
because a value typed `any` defeats the checker rather than merely
inconveniencing it. This document classifies the from-any sites by the
shape of the site, and names for each shape the mechanism that would
close it.

The document holds no counts: what each class IS and what would retire
it is durable, while how many sites a class has today is derived, and
the `## Method` command derives it in a second. Every site quoted below
is quoted in the fenced form, so `--make ci` compares the quote against
its source line on every run — a site that closes fails the gate here,
and the document cannot silently describe a tree that has moved.

## Method

The site list:

```text
git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"
```

Some of those hits are the reason text quoted inside test fixtures
rather than casts — `_build/casts_test.tl`, `_cli/assert_lint_test.tl`
and `_tool/lint_test.tl` all hold a fixture line that says `-- cast:
from any` as data. The grep cannot tell them apart; `_build/casts.tl`
can, because it counts `as` tokens through the linter's lexer.

The from-any bucket against every other cast reason:

```text
git ls-files '*.tl' | xargs grep -h -- "-- cast: " | wc -l
git ls-files '*.tl' | xargs grep -h -- "-- cast: " | grep -c "from any"
```

## Classes

Seven shapes, disjoint: every site belongs to exactly one. Where two
descriptions fit a site, the more specific one takes it — a column read
off a sqlite row is a row read, not a generic map walk, and a value that
arrived from a decoder is decoded data however it is then indexed.

### Decoded-data shaping

A value that came out of `json.decode`, `literal.parse`, a loaded config
chunk, or a decoded report, then reshaped or read field by field into a
known record. The purest form is a run of consecutive fields lifted off
one decoded table, each read costing its own cast; the test form casts
the decoded value to the shape the test then asserts on.

**What closes it.** Partly, tools already in the tree:
`cosmic/json.tl:135` declares `decode_object(str): {string: any} | nil,
string` and `cosmic/json.tl:155` declares `decode_array(str): {any} |
nil, string`, so a `json.decode(s) as {string: any}` site is a call
change and nothing more. That closes the top level only. The field reads
underneath it need a decode that validates into a declared record and
returns it typed — one API, applicable at every site in this class.

### Any-map field walk

Indexing a value the code knows is a table but whose type is `any` or
`{string: any}`, one field at a time down a path. Each step of the path
costs a cast, so a two-level read costs two. The values are box
configuration, tl syntax-tree nodes, and coverage records — real
structures with real shapes that no record describes.

**What closes it.** A declared record per shape, which is ordinary work
with no missing mechanism behind it: the box configuration and the
coverage record are cosmic's own data and can simply be typed. Where the
value genuinely is dynamic, `is {string: any}` dispatch narrows without a
cast and is already available. Sites accumulate here because nobody has
written the records, not because anything blocks writing them.

### sqlite row column read

A `Row` is `{string: any}`, so reading a column with a known type costs
a cast at every read: `row.name as string`, `(row.c as number)`.

**What closes it.** Typed column accessors on `Row` — a `text`,
`number`, `integer` and `blob` reader that takes the column name and
returns the declared type or fails. The row's dynamic shape is real (a
query's columns are known only at runtime), so the record cannot be
typed; the accessor is what moves the check from the caller's cast to
one place that can fail honestly.

### Dynamic-value boundary

A value whose type genuinely is not knowable at the boundary it crosses:
a `pcall`, `load`, `require`, `coroutine.resume` or `package.loaded`
return, and the `any`-typed parameters cosmic's own APIs declare. The
live site is one of the latter — a response constructor handed to
`fetch`'s extras, declared to take `any` and immediately re-shaped:

```text
-- cosmic/fetch/init.tl:384
    return make_response(t as {string: any}) -- cast: from any
```

**What closes it.** Two different things, which is why this class does
not collapse into one item. Repeated `pcall(require, ...)` sites want one
typed helper that returns the module or nil; the `any`-typed parameters
want the API to declare what it actually accepts, a union or a record
rather than `any`. What is left after both — `load` of an arbitrary
chunk, a resumed coroutine's values — is dynamic by nature and closes
only with an `is` guard at the point of use.

### Binding boundary

A `cosmo.*` or Lua-stdlib call whose generated declaration types the
return `any`, or returns an untyped tuple the caller has to type slot by
slot. An `E*` constant looked up by name off the `unix` table, and a
signal number looked up the same way:

```text
-- cosmic/errno.tl:52
  return (unix as {string: any})[name] as integer -- cast: dynamic E* lookup, from any
```

```text
-- cosmic/quicksand/proc.tl:262
    local n = by_name[s] as integer -- cast: from any
```

An `fcntl` return that is an integer for every command cosmic passes:

```text
-- cosmic/fd.tl:187
    return result as integer -- cast: from any
```

A zip reader handle, and `cosmo.Fetch`'s dual-shape second return, which
is the headers table on success and the error string on failure — one
declaration covering both, so the success path re-types it at each of
the two call sites that read it:

```text
-- cosmic/zip.tl:222
    return make_archive("read", {reader = handle as zip.Reader}) -- cast: from any
```

```text
-- cosmic/fetch/init.tl:239
  local headers, raw_headers = fetch_headers.normalize(headers_or_err as {string: any})
```

```text
-- cosmic/fetch/init.tl:367
  local headers, raw_headers = fetch_headers.normalize(headers_or_err as {string: any})
```

**What closes it.** Not cosmic. `_types/gentype.tl` generates these
declarations from `tool/net/definitions.lua` in `whilp/cosmopolitan`, so
the annotation there is the source: a binding annotated with its
concrete return type emits a concrete Teal type and the cast at the call
site disappears. That makes this class a change in the other repository,
landed as its own work, followed by a pin bump here.

### Untyped-probe fallout

A test that deliberately re-types an API to feed it input the real
signature forbids, or reaches a surface the type deliberately does not
describe. The invalid-input form re-types a constructor as
`function(any): any, any` so it can pass a bad argument, and everything
read off that call is then `any`. The surface form walks the published
modules by name, which no type describes; it narrows with an `is`
guard at the point of use rather than a cast.

**What closes it.** For the invalid-input probes, one test helper that
performs the untyped call and hands back a typed `(nil, string)` — the
tests all want the same thing, which is to assert on an error message.

### Fixture text, not a cast

Not a cast at all: a string literal holding `-- cast: from any` as
fixture input for a lint's own test. `_build/casts_test.tl` feeds it to
the cast counter, and `_cli/assert_lint_test.tl` and `_tool/lint_test.tl`
feed the same shape to the justification rules.

**What closes it.** Nothing, because nothing is broken: the counter and
the lint rules both walk tokens through the linter's lexer, so a cast
quoted inside a string is neither counted nor flagged, and
`_build/casts_baseline.tl` carries no row for a file whose only `as` is
test data. The class is here because the census command is a grep, and a
grep cannot tell code from a quoted example of code.

## What no mechanism closes

Two of the seven have no tool waiting for them.

**Decoded-data shaping** below its top level. `json.decode_object` and
`json.decode_array` type the outermost table and stop; nothing in the
tree turns a decoded table into a declared record with the fields
checked. That missing piece is a cosmic API — a decode that takes the
target record and validates into it.

**Binding boundary** returns. The declarations are generated, so no edit
in this repository can improve them; the fix is an annotation in
`whilp/cosmopolitan`'s `tool/net/definitions.lua`, which then flows here
as a pin bump. Nothing in the carried tl patch (`3p/tl/tl_patch.tl`) or
upstream tl is implicated — these are honest `any` declarations, not
narrowing gaps.

Everything else here is ordinary work against mechanisms that already
exist: records nobody has written, accessors nobody has added, and calls
that should be using the typed decoder already shipping.

## What this is not

Not a floor and not a gate. `_build/casts_baseline.tl` is the ratchet
that holds the cast count down, per file, and `cosmic --check lint` is
what enforces the justification comment; this document is the map that
says what the remaining sites are and in what order they can be closed.
