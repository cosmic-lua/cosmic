# casts

Every `as` cast in this tree carries a `-- cast: <reason>`
justification, enforced by `cosmic --check lint`. This document
classifies all of them: what each class of cast IS, and what would
retire it. Each class gets exactly one of three verdicts. **What closes
it here** means the mechanism exists in this repository, or writing it
is ordinary work. **What closes it upstream** means the fix belongs in
`cosmic-lua/cosmopolitan`'s `tool/net/definitions.lua` or in tl, and arrives
as a pin bump. **Why it is a floor** means no mechanism closes it
without deleting the thing the cast serves.

The document holds no counts: what a class IS and what would retire it
is durable, while how many sites it has today is derived. Every site
quoted below is quoted in the fenced form, so `--make ci` compares the
quote against its source line on every run — a site that closes fails
the gate here, and the document cannot silently describe a tree that
has moved.

## Method

The authoritative total is the committed per-file floor, which
`_build/casts.tl` produces by walking `as` tokens through the linter's
lexer:

```text
awk -F'= ' '/\] = /{gsub(/,/,"",$2); s+=$2} END {print s}' \
  _build/casts_baseline.tl
```

A grep for the justification comment counts higher — 11 higher today —
because a `-- cast: ` string can appear in a file without being a cast.
The lint's own fixtures and doc comments quote the reason text as data,
and a grep cannot tell code from a quoted example of code. That
divergence is confined to five files: `_build/casts.tl`,
`_build/casts_test.tl`, `_cli/assert_lint_test.tl`, `_cli/lint.tl` and
`_tool/lint_test.tl`; everywhere else the two agree file for file. Use
the lexer — `_cli.lint.cast_lines(content, file)` returns the real cast
lines, and `_build/casts.tl` is its one caller.

```text
git ls-files '*.tl' | xargs grep -h -- "-- cast: " | wc -l
```

The reason census, which the classes below were read from:

```text
git ls-files '*.tl' | xargs grep -ho -- "-- cast: .*" \
  | sed 's/-- cast: //; s/ *(.*//' | sort | uniq -c | sort -rn
```

Reason text is a signal, not the classification: the same shape appears
under several spellings and one spelling spans two shapes, so every
site below was read rather than pattern-matched.

The site inventory is committed beside this document as
`docs/design/cast-sites.tsv`: one row per cast, holding the path, the
line the `as` token is on, and the class. The reason comment is not
always on the cast's line — for roughly a third of the sites it stands
alone on the line above — so a `file:line` join between the grep's
output and the lexer's mismatches on all of those. Where the inventory
and this prose disagree, the inventory is right.

The inventory is half generated, half curated. Its path and line
columns are `_cli.lint.cast_lines`' answer, the same lexer
`_build/casts.tl` counts with — a fact about the tree, reproducible by
a walk. Its class column is this document's judgment about what each
site is for, which no walk can produce. So there is no full
`--baseline`-style regen: `bin/cosmic --make run _build/cast_sites.tl
--reconcile` re-derives path and line, carries the class forward for
every site that still exists, drops a row whose site is gone, and
refuses to write — naming the site instead — when a cast has appeared
with no prior row to carry a class from, because a blank class is a
worse map than a stale one. `_build/cast_sites_test.tl` gates the
committed file against a fresh reconcile: its per-file counts against
`_build/casts_baseline.tl`, every class against a `### ` heading here
and back, and every row's line against a real cast by the lexer, never
a grep.

## Classes

Every cast belongs to exactly one class. Where two descriptions fit a
site, the more specific one takes it: a column read off a sqlite row is
a row read rather than a generic map view, a test that re-types an API
to defeat it is a probe rather than whatever shape the re-typing takes,
and a value typed by a `cosmo.*` declaration is a binding site rather
than a narrowing one.

### type-defeating test probe

A test that re-types an API to feed it input the real signature
forbids, or to reach a surface the type deliberately hides, so the
runtime guard can be exercised. `check.refuses` is the shared helper
for the invalid-input half, `check.is_exposed` for the absent-surface
half, and together they carry the class's two library casts.

```text
-- cosmic/hash_test.tl:233
  local ok, err = pcall(hash.digest, "md4" as hash.Algo, "abc")
```

**Why it is a floor.** A test that proves a runtime guard rejects input
the type forbids must first defeat the type; remove the cast and the
test goes with it. The class is compressible, not closable: every
probe can route through a helper, and two helpers is the floor.

### userdata boundary

A raw userdata handle from a binding, re-typed to the record that
describes it; or a method table typed `{string: any}` whose `self` is
`any`, re-typed once per method. Teal's `userdata` member makes `is`
narrow such a record, but cannot type an untyped handle in the first
place.

```text
-- cosmic/fs/types.tl:279
    return raw as fs_types.Stat -- cast: userdata boundary
```

**Why it is a floor.** A userdata value has no structure Teal can read,
so the record describing it is an assertion, and the assertion has to
be written somewhere. The floor is one cast per handle type at its wrap
point — six today — with the per-method casts collapsing into those.

### tl compiler surface

The narrowed tl API types a parsed program, its statements and its
environment as `any`, so every field read, array view and method beyond
the curated surface costs a cast. Nothing here describes those shapes,
because the AST is deliberately not part of what the extraction emits.

```text
-- _tool/discover.tl:87
    local node = stmt as {string: any} -- cast: tl AST node fields
```

**What closes it upstream.** tl is where the AST node types live, and
`_types/gentl.tl` erases them by rule because the upstream records
carry internal fields no consumer should depend on. A published node
type in tl emits a concrete record, arriving here as a tl pin bump.

### binding contract shape

A `cosmo.*` declaration whose type is the union of every shape the C
function can take or return: a tuple whose slots are all
`success | failure`, a return typed `any`, or a parameter widened to
cover every accepted form. The caller has guarded; the declaration has
not.

```text
-- cosmic/time.tl:132
    return nil, errno.format(mon as string, "gmtime") -- cast: tuple element
```

**What closes it upstream.** These declarations are generated from
`tool/net/definitions.lua` in `cosmic-lua/cosmopolitan`, so the annotation
there is the source: concrete per-slot return types emit concrete Teal
types and the call-site cast disappears, arriving here as a pin bump.

### proved-value narrowing

A `T | nil` re-typed to `T` because the code above established that the
nil cannot occur — by an early-exit guard, by an `or` fallback that
cannot itself be nil, or by a fact about the environment a test runs
in. These casts do not make the code compile; they state the intent.

```text
-- _make/root.tl:67
      local hits = (fs.glob(cmd, pattern) or {}) as {string} -- cast: or keeps the nil union
```

**What closes it here.** The mechanisms ship already. `check.must`
turns a fallible call into a plain value in tests, which is what the
`fs.cwd()` sites want; the carried patch already narrows `x or
fallback` and below an early-exit guard, so several are dead weight.

### enum relation

An enum value used where a plain `string` is wanted, or one enum's word
set used where a wider enum is declared even though every word of the
narrow set is a word of the wide one. Teal relates neither pair, so a
relation the reader verifies by eye costs a cast.

```text
-- cosmic/hash.tl:104
    string.upper(algo) as cosmo.CryptoHashName, data) -- cast: enum widening
```

**What closes it upstream.** The subtyping rule is tl's: an enum whose
words are a subset of another's is a subtype of it, and every enum is a
subtype of `string`. Both are narrowing rules of the kind the carried
patch holds (`3p/tl/tl_patch/`), so both close as a patch plus a bump.

### runtime capability probe

Code that asks at runtime whether a surface exists, because the answer
depends on the runtime or on which binary is loaded rather than on the
types: whether this platform's `proc` carries `pledge`, whether a
reader implements the delimiter capability, whether a module predates a
function.

```text
-- cosmic/stream.tl:237
  local dr = r as stream.DelimReader -- cast: duck-typed capability probe
```

**Why it is a floor.** The question is unanswerable at check time by
construction: a type says what a value is in the tree being checked,
and the probe exists because the value may come from a different tree.
Each probed shape needs one cast to name what it found — five today.

### metatable access

`getmetatable` and `debug.getmetatable` return `any` by definition, so
an identity compare against a known metatable, or a read of a
metamethod off one, costs a cast at every site. The `__close` tests use
the second form; the sqlite blob check uses the first.

```text
-- cosmic/sqlite/bind.tl:40
  return getmetatable(v) == blob_mt as any -- cast: metatable identity compare
```

**Why it is a floor.** A metatable is a table whose type is whatever
its owner made it; Lua's contract for `getmetatable` returns a value of
no particular type, and a typed wrapper would assert the same thing one
level down. Two helpers — identity compare and metamethod fetch.

### function shape

An overloaded binding declared as a union of signatures, with one arm
selected by casting the function before calling it. The unix socket
calls are the pure case: `bind` and `connect` take either a sockaddr or
a filesystem path, and one declaration covers both.

```text
-- cosmic/net/socket.tl:334
    local ok, err = (unix.bind as function(number, string): (boolean, string))(fd, path)
```

**What closes it upstream.** `tool/net/definitions.lua` declares one
function per C entry point, so an overload is one annotation covering
two contracts. Splitting the overloaded entries into separately
annotated names removes the cast at every call site.

### container variance

A container re-typed to another container type Teal will not relate: an
array read as a map or the reverse, a map widened at its key or value
type, an element enum where the element is `string`, a bare `table`
narrowed to a shape. Teal's containers are invariant.

```text
-- cosmic/sqlite/bind.tl:120
  local list = params as {any} -- cast: array-part probe of the params table
```

**What closes it upstream.** Covariance on reads is the missing tl
rule: `{Promise}` where `{string}` is wanted, and `{string: Rule}`
where `{string: any}` is wanted, are sound everywhere this tree uses
them. The bare-`table` sites are the exception and want a union.

### numeric narrowing

A value the code has established is an integer, declared `number`:
digits just parsed by `tonumber` with an explicit base, a computation
bounded above and below, a value a `math.type` check has already
sorted, or a tl API field reporting a line or column.

```text
-- cosmic/fs/octal.tl:23
  return tonumber(digits, 8) as integer -- cast: octal digits parse integral
```

**What closes it upstream.** `math.type(x) == "integer"` is a guard the
checker could narrow on, exactly as it narrows a nil union, and
`tonumber(s, base)` over a digit string is integral by Lua's contract.
Both are checker rules, so both land in the patch or upstream in tl.

### dynamic name lookup

A table indexed by a name computed at runtime, where the declared type
cannot say what any single name maps to: a verb registry keyed by verb
name, a `package.searchers` slot, a module fetched through an
indirection that defeats static resolution.

```text
-- _make/init.tl:143
  local v = by_name("build") as Verb -- cast: the registry defines it
```

**What closes it here.** The registry is this tree's own data. A
`by_name` returning `Verb | nil` closes seven of these outright, and
the guard that follows is one the checker already narrows. The searcher
slot wants a declared record and nothing more.

### generic T

A fresh table, a map view, or a value pulled out of a dynamic walk,
re-typed as a generic parameter, because Teal cannot relate the
concrete thing the body built to the `T` the signature promised. Every
site sits in a generic whose contract is honest and unprovable inside.

```text
-- cosmic/deep.tl:52
  return copy_impl(value, {}) as T
```

**Why it is a floor.** The body of a generic function cannot construct
a value of its own type parameter: only the caller knows what `T` is,
and the walk underneath is dynamic by design. Eight sites, one per
generic body that returns a constructed value, already incompressible.

### module surface record

A `require` result, or a freshly loaded chunk, re-typed to a
hand-written record naming only the part the caller uses. The record is
a deliberate narrowing rather than a workaround — it documents the seam
— but it is spelled as a cast.

```text
-- _types/gentype.tl:19
local render = require("_types.gentype_render") as GentypeRender -- cast: narrow surface
```

**What closes it here.** These are this tree's own modules, and the
narrow record is the module's real contract written on the wrong side
of the seam. Declaring it in the module's own source and returning it
typed makes the plain `require` resolve to that type.

### decoded data shaping

A value that came out of `literal.parse`, a decoded config or a parsed
baseline, then read field by field or narrowed into a declared record.
The outermost table is typed by the decoder; everything under it is
`any`, so each field read costs its own cast.

```text
-- _tool/coverage/baseline.tl:138
  return {covered = covered as integer, total = total as integer} -- cast: math.type checked above
```

**What closes it here.** `cosmic.shape` already validates a value
against a declared spec and returns it typed, which is the
decode-into-a-record step these sites hand-roll. Routing the baseline
and pin readers through it replaces the field-wise casts with one call.

### record union after guard

A union re-typed after a guard the checker does not carry to the use:
the guard sits on a record FIELD rather than a plain variable, or it
proved which arm of a record union a value is on in a way `is` cannot
express. The fact is established; it does not survive to the next line.

```text
-- _make/stage.tl:183
  local sel = v.select as Selection -- cast: a graph verb always has one
```

**What closes it upstream.** Record-field narrowing is the named gap: a
guard on `v.select` narrows nothing, and the documented workaround is
to copy the field to a local. Carrying a guard on a field — invalidated
by any assignment to it — is a narrowing rule, so it lands in tl.

### incremental record construction

A table assembled field by field, or seeded empty and filled by the
lines that follow, re-typed to the record it satisfies once the filling
is done. Teal checks a record literal but has nothing to say about a
table built up over several statements.

```text
-- cosmic/sqlite/row_iter.tl:64
  local iter = setmetatable({} as Rows, { -- cast: table seeded as record
```

**What closes it here.** Most of these can be written as record
literals, which the checker verifies field by field: the module tables
and the response constructor have every value in scope already. The
iterator wants its field set declared up front, closures assigned after.

### pcall return shape

`pcall` returns a boolean and then whatever the call returned, which
the checker can only spell as `any`, so a caller that knows the
protected function's signature re-types the tuple. Slot two is a raised
error on failure and the callee's first return on success.

```text
-- cosmic/shm.tl:146
    local ok, err = pcall(raw.write, raw, off, data, write_count) as (boolean, any)
```

**What closes it upstream.** `pcall` is a checker special case, not an
ordinary function: tl knows the callee's type at the call site and
could type the success arm from it, leaving the failure arm as the
error type. That rule lands in the carried patch or upstream in tl.

### binding constant by name

A `cosmo.unix` constant resolved by a name computed at runtime — an
`E*` errno name, a `SIG*` signal name — which needs the module table
viewed as a map and the result re-typed to `integer`. The constants are
declared correctly; looking one up by name has no typed surface.

```text
-- cosmic/errno.tl:52
  return (unix as {string: any})[name] as integer -- cast: dynamic E* lookup, from any
```

**What closes it upstream.** `cosmic-lua/cosmopolitan` holds the constants
and can expose them as real maps — one `{string: integer}` for the
errno names and one for the signal names — annotated so the generator
emits typed tables. The lookup becomes a map read with an honest `| nil`.

### map view of a declared value

A value this tree gave a type — a record, a stdlib module table, or a
parameter it declared `any` at a module seam — re-typed to
`{string: any}` so code can assign through a computed key, or so two
modules can pass a value without a circular type dependency.

```text
-- cosmic/coverage/init.tl:92
  local co = coroutine as {string: any} -- cast: patch stdlib table
```

**What closes it here.** Declaring the type is the whole fix, and the
type is knowable in every case: a narrow record for the two stdlib
functions the coverage hook swaps, the walker taking the record it
walks, and the response callback declaring the map it accepts.

### sqlite row column read

A `Row` is `{string: any}`, so reading a column whose type the query
already fixes costs a cast at every read.

```text
-- cosmic/sqlite/lifecycle_test.tl:12
  return check.must(db:query_one("SELECT COUNT(*) AS n FROM t")).n as integer
```

**What closes it here.** Typed column accessors on `Row` — a `text`,
`number`, `integer` and `blob` reader taking the column name and
returning the declared type or failing. The row's dynamic shape is
real, so the accessor is what makes the check fail honestly.

## The floor

Five classes carry the verdict **Why it is a floor**: type-defeating
test probe, userdata boundary, runtime capability probe, metatable
access, and generic T. Together they hold 71 of the tree's casts today,
by `docs/design/cast-sites.tsv`. They do not all stay that size — four
of the five compress hard, because the shape repeats and one helper can
carry it. Summing each class's smallest reachable count — six wrap
points, two probe helpers, five probed shapes, two metatable helpers
and eight generic bodies — puts the floor at **23**.

That number is what the win condition has to answer to. G3's measure in
`docs/goals.md` is zero `as` casts, and these 23 are not casts standing
in for work nobody has done: they are the places where a type system
that cannot see userdata, cannot see a metatable, cannot see another
binary's surface, and cannot see inside its own generics has to be
told. Reaching literal zero means deleting what they serve — the tests
that prove the runtime guards refuse bad input, the typed wrappers over
`cosmo.*` handles, the generic copy and merge.

So the question, which this document puts and does not answer: does G3
keep zero as a literal target and accept that it is reached by deleting
those, or does it become zero outside a named floor — the justified
casts no mechanism closes, held per class and ratcheted by
`_build/casts_baseline.tl` — with a further condition on the test half,
since 26 of the 71 are test probes and a probe behind one named helper
is a different thing from a probe written by hand at each site? That is
the goal owner's call, made by amending `docs/goals.md`, not here.

## What this is not

Not a floor and not a gate. `_build/casts_baseline.tl` is the ratchet
that holds the cast count down, per file; `cosmic --check lint` enforces
the justification comment and checks this document's citations against
the tree; `docs/design/cast-sites.tsv` is the site inventory, held
against the baseline and against this document's headings by
`_build/cast_sites_test.tl`. This document is the map: what the
remaining sites are, which can be closed, and by whom.
