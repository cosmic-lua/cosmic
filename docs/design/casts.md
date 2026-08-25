# from-any casts

Every `as` cast in this tree carries a `-- cast: <reason>`
justification, and `from any` is the reason on 192 of the 402 — the
largest single bucket, and the one standing furthest between the tree
and G3's zero-cast win condition. This document classifies all 192 by
the shape of the site, and names for each shape the mechanism that
would close it.

Measured against `d3e59de7` on 2026-08-25. The counts here are a
snapshot of that commit, re-derived by the commands below.

The reason text itself carries no signal: 189 of the 192 sites say
exactly `from any` and nothing more, so the class comes from reading
the code at each site.

## Method

The site list, and the per-file counts every table below is built from:

```text
git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"
git ls-files '*.tl' | xargs grep -c -- "-- cast: .*from any" | awk -F: '$2>0'
```

The bucket's size against every other cast reason:

```text
git ls-files '*.tl' | xargs grep -h -- "-- cast: " | wc -l
git ls-files '*.tl' | xargs grep -h -- "-- cast: " | grep -c "from any"
```

A file appears under every class it has sites in, so the per-class
tables sum to 192 while the file rows outnumber the 63 files that
carry a site.

## Classes

Seven shapes, disjoint: every site belongs to exactly one. Where two
descriptions fit a site, the more specific one takes it — a column read
off a sqlite row is a row read, not a generic map walk, and a value that
arrived from a decoder is decoded data however it is then indexed.

### Decoded-data shaping

A value that came out of `json.decode`, `literal.parse`, a loaded
config chunk, or a decoded report, then reshaped or read field by field
into a known record. `_eval/score.tl:194` is the pattern at its purest —
ten consecutive fields lifted off one decoded table, each with its own
cast — and `cosmic/json_test.tl:6` is the test form, where the decoded
value is cast to the shape the test then asserts on.

**What closes it.** Partly, tools already in the tree:
`cosmic/json.tl:135` declares `decode_object(str): {string: any} | nil,
string` and `cosmic/json.tl:155` declares `decode_array(str): {any} |
nil, string`, so a `json.decode(s) as {string: any}` site is a call
change and nothing more. That closes the top level only. The field reads
underneath it need a decode that validates into a declared record and
returns it typed — one API, applicable at every site in this class,
and the largest single win available anywhere in this document.

| file | sites |
| --- | --- |
| _build/size.tl | 1 |
| _eval/score.tl | 10 |
| _eval/score_test.tl | 12 |
| _eval/stage.tl | 8 |
| _eval/stage_test.tl | 3 |
| _make/pin_test.tl | 2 |
| _perf/baseline.tl | 1 |
| _perf/compare.tl | 1 |
| _tool/coverage/report.tl | 2 |
| _tool/doc/index_test.tl | 1 |
| cosmic/fetch/verbs_test.tl | 1 |
| cosmic/json_test.tl | 10 |
| cosmic/literal_test.tl | 7 |
| cosmic/teal_config_test.tl | 2 |
| **total** | 61 |

### Any-map field walk

Indexing a value the code knows is a table but whose type is `any` or
`{string: any}`, one field at a time down a path. Each step of the path
costs a cast, so a two-level read costs two:
`cosmic/quicksand/box/merge_test.tl:22` spends both on one line. The
values are box configuration, tl syntax-tree nodes, and coverage
records — real structures with real shapes that no record describes.

**What closes it.** A declared record per shape, which is ordinary work
with no missing mechanism behind it: the box configuration and the
coverage record are cosmic's own data and can simply be typed. Where the
value genuinely is dynamic, `is {string: any}` dispatch narrows without
a cast and is already available. This class is large because nobody has
written the records, not because anything blocks writing them.

| file | sites |
| --- | --- |
| _tool/coverage/lines.tl | 6 |
| cosmic/check.tl | 2 |
| cosmic/deep_example.tl | 5 |
| cosmic/deep_test.tl | 8 |
| cosmic/fetch/headers.tl | 2 |
| cosmic/fetch/init.tl | 3 |
| cosmic/format/init.tl | 4 |
| cosmic/fs/types.tl | 2 |
| cosmic/quicksand/box/init_test.tl | 2 |
| cosmic/quicksand/box/merge.tl | 4 |
| cosmic/quicksand/box/merge_test.tl | 14 |
| cosmic/quicksand/proxy/rules.tl | 1 |
| cosmic/sandbox/init_test.tl | 2 |
| **total** | 55 |

### sqlite row column read

A `Row` is `{string: any}`, so reading a column with a known type costs
a cast at every read: `row.name as string`,
`(row.c as number)`. `cosmic/sqlite/init_test.tl` spends six that way
and `cosmic/sqlite/advanced_test.tl` two.

**What closes it.** Typed column accessors on `Row` — a `text`,
`number`, `integer` and `blob` reader that takes the column name and
returns the declared type or fails. The row's dynamic shape is real (a
query's columns are known only at runtime), so the record cannot be
typed; the accessor is what moves the check from the caller's cast to
one place that can fail honestly.

| file | sites |
| --- | --- |
| cosmic/sqlite/advanced_test.tl | 2 |
| cosmic/sqlite/close_test.tl | 1 |
| cosmic/sqlite/init_test.tl | 6 |
| **total** | 9 |

### Dynamic-value boundary

A value whose type genuinely is not knowable at the boundary it crosses:
a `pcall`, `load`, `require`, `coroutine.resume` or `package.loaded`
return, and the `any`-typed parameters cosmic's own APIs declare —
`bind_at(raw_stmt, i, v: any)` in `cosmic/sqlite/bind.tl:52`, the
callback context in `cosmic/fs/path_test.tl:180`. The five sites that
`pcall(require, "cosmic._version")` and then read `.cosmic` off the
result appear in five different files.

**What closes it.** Two different things, which is why this class does
not collapse into one item. The repeated `pcall(require, ...)` sites
want one typed helper that returns the module or nil — the version
lookup alone accounts for five of them. The `any`-typed parameters want
the API to declare what it actually accepts, a union or a record rather
than `any`. What is left after both — `load` of an arbitrary chunk, a
resumed coroutine's values — is dynamic by nature and closes only with
an `is` guard at the point of use.

| file | sites |
| --- | --- |
| _cli/main_handlers.tl | 1 |
| _docs/publish_test.tl | 1 |
| _eval/stage.tl | 1 |
| _perf/harness_test.tl | 3 |
| _perf/perf_test.tl | 1 |
| _perf/run.tl | 3 |
| _tool/benchmark.tl | 1 |
| cmd/cosmic/main.tl | 2 |
| cosmic/_script_cache.tl | 1 |
| cosmic/_seal_coverage.tl | 3 |
| cosmic/_teal_engine.tl | 1 |
| cosmic/coverage/init.tl | 3 |
| cosmic/doc/query.tl | 1 |
| cosmic/fetch/extras.tl | 2 |
| cosmic/fs/path_test.tl | 1 |
| cosmic/init.tl | 2 |
| cosmic/quicksand/box/init.tl | 2 |
| cosmic/quicksand/box/run.tl | 1 |
| cosmic/rand_test.tl | 1 |
| cosmic/searcher_test.tl | 1 |
| cosmic/sqlite/bind.tl | 2 |
| cosmic/sqlite/extras.tl | 4 |
| **total** | 38 |

### Binding boundary

A `cosmo.*` or Lua-stdlib call whose generated declaration types the
return `any`, or returns an untyped tuple the caller has to type slot by
slot. `cosmic/signal.tl:259` types three slots of one `sigaction`
return; `cosmic/url.tl:64` casts `cosmo.ParseParams` to `{{string}}`;
`cosmic/errno.tl:52` looks an `E*` constant up by name off the `unix`
table.

**What closes it.** Not cosmic. `_types/gentype.tl` generates these
declarations from `tool/net/definitions.lua` in `whilp/cosmopolitan`,
so the annotation there is the source: a binding annotated with its
concrete return type emits a concrete Teal type and the cast at the
call site disappears. That makes this class a change in the other
repository, landed as its own work, followed by a pin bump here.

| file | sites |
| --- | --- |
| cosmic/coverage/init.tl | 3 |
| cosmic/errno.tl | 1 |
| cosmic/fd.tl | 1 |
| cosmic/quicksand/proc.tl | 1 |
| cosmic/signal.tl | 3 |
| cosmic/teal.tl | 1 |
| cosmic/url.tl | 2 |
| cosmic/zip.tl | 1 |
| **total** | 13 |

### Untyped-probe fallout

A test that deliberately re-types an API to feed it input the real
signature forbids, or reaches a surface the type deliberately does not
describe. `cosmic/quicksand/box/run_test.tl:114` re-types
`quicksand.new` as `function(any): any, any` so it can pass a bad
promise; everything read off that call — the error especially — is then
`any`, and each read costs a cast. `cosmic/surface_test.tl:92` and the
`__close` metamethod reads in `cosmic/sqlite/close_test.tl` are the
other form: the test is checking something the type system is not
supposed to admit.

**What closes it.** For the invalid-input probes, one test helper that
performs the untyped call and hands back a typed `(nil, string)` —
the tests all want the same thing, which is to assert on an error
message. For the surface probes, nothing should: a test that asserts a
type deliberately hides something is doing its job, and its cast is
honest. That half is a candidate for a reason of its own rather than
for closure.

| file | sites |
| --- | --- |
| cosmic/fd_read_test.tl | 1 |
| cosmic/fs/find_close_test.tl | 1 |
| cosmic/quicksand/box/init_test.tl | 7 |
| cosmic/quicksand/box/run_test.tl | 1 |
| cosmic/sqlite/close_test.tl | 2 |
| cosmic/surface_test.tl | 3 |
| **total** | 15 |

### Fixture text, not a cast

One site, and it is not a cast at all:
`_build/casts_test.tl:67` is a string literal holding
`"local a = x as {string} -- cast: from any"` — fixture input for the
casts lint's own test. The lint counts it, so
`_build/casts_baseline.tl` carries a row for a file whose casts are
test data.

**What closes it.** A scanner that skips string literals, in the check
that produces the baseline. The count is off by one today; the reason
it matters is that a lint which cannot tell code from a quoted example
of code will miscount any file that documents the rule it enforces.

| file | sites |
| --- | --- |
| _build/casts_test.tl | 1 |
| **total** | 1 |

## What no mechanism closes

Two of the seven have no tool waiting for them.

**Decoded-data shaping** below its top level. `json.decode_object` and
`json.decode_array` type the outermost table and stop; nothing in the
tree turns a decoded table into a declared record with the fields
checked. That missing piece is a cosmic API — a decode that takes the
target record and validates into it — and it is worth roughly a third of
this document on its own.

**Binding boundary** returns. The declarations are generated, so no
edit in this repository can improve them; the fix is an annotation in
`whilp/cosmopolitan`'s `tool/net/definitions.lua`, which then flows
here as a pin bump. Nothing in the carried tl patch
(`3p/tl/tl_patch.tl`) or upstream tl is implicated — these are honest
`any` declarations, not narrowing gaps.

Everything else in this document is ordinary work against mechanisms
that already exist: records nobody has written, accessors nobody has
added, and calls that should be using the typed decoder already
shipping.

## What this is not

Not a floor and not a gate. `_build/casts_baseline.tl` is the ratchet
that holds the cast count down, per file, and `cosmic --check lint` is
what enforces the justification comment; this document is the map that
says what the remaining sites are and in what order they can be closed.
The numbers go stale the moment a site closes, and the `## Method`
commands re-derive them in seconds — read them, do not trust the table.
