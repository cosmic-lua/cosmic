## Goal

G3 — an honest type layer, no escape hatches. The parent (`3IOegofM`)
holds the 38 decoded-data shaping `from any` casts in test files. Its
sibling slice closes the 21 whose test merely CONSUMES decoded data.
These 17 are the residue: tests whose subject IS the dynamic decode, so
a validating decode would change what is under test rather than close a
cast. The deliverable is a per-site decision — a narrowing, a call
change, or a cast whose stated reason is true — not a count that
necessarily falls to zero.

## Evidence

Re-measured 2026-08-26 against `whilp/cosmic` `fb2587ad` (`main`);
first measured 2026-08-25 at `cd87a765`, and nothing in this section
moved between the two except the two baseline rows' line numbers. Two
files, 17 sites, every one a `from any` cast and no other cast in
either file (`grep -c -- "-- cast:" <file>` reports 10 and 7, matching
their `_build/casts_baseline.tl` rows, which sit on lines 58 and 61 at
`fb2587ad` — the file is alphabetical and every landing shifts them, so
find each row by name, never by line).

**`cosmic/json_test.tl` — 10 sites, 324 lines** (176 of headroom under
the 500-line cap). `grep -n -- "-- cast: .*from any"`:

| line | site | note |
| --- | --- | --- |
| 6 | `json.decode('{"a":1,"b":"hello"}') as {string: any}` | object |
| 14 | `json.decode('[1,2,3]') as {number}` | array |
| 103 | `json.decode(encoded) as {string: any}` | object |
| 105 | `decoded.nested as {string: boolean}` | nested read |
| 174 | `json.decode('{"a":null,"b":1}') as {string: any}` | null policy |
| 186 | `json.decode("[1,null,2]") as {any}` | null policy |
| 198 | `json.decode("[1,null,2]") as {any}` | null policy |
| 205 | `json.decode("[1,null,2]", {null_value = json.null}) as {any}` | null policy |
| 208 | `json.decode('{"a":null,"b":1}', {null_value = json.null}) as {string: any}` | null policy |
| 273 | `json.decode('"\\u0000"') as string` | scalar |

`cosmic/json.tl` already declares the two narrower entry points the
first four could use — `decode_object(str: string): {string: any} | nil,
string` (`:135`) and `decode_array(str: string): {any} | nil, string`
(`:155`). **That is the decision this slice has to make and state**:
`cosmic/json_test.tl` is the json module's own test file, so swapping
`decode` for `decode_object` at a site changes WHICH function is under
test. The five null-policy sites (174–208) pin `decode`'s handling of
JSON `null` specifically and cannot swap at all. `:273` decodes a
scalar, which neither narrower entry point accepts.

**`cosmic/literal_test.tl` — 7 sites, 453 lines** (47 of headroom, the
tighter of the two):

| line | site |
| --- | --- |
| 143–145 | `shallow.a`, `a.b`, `b.c`, each `as {string: any}` |
| 212 | `got.nested as {string: any}` |
| 251 | `got["a\tkey"] as {string: any}` |
| 270, 280 | `got["a.tl"] as {string: any}` |

`:143`–`:145` walk a deliberately-nested value to prove nesting is
accepted; `:251` proves a tab in a bracket key survives. Validating
those into a declared record would assert the shape the test is trying
to DISCOVER.

**What `cosmic.shape` can and cannot do here.** `cosmic/shape.tl` (318
lines) validates into a declared record; its contract says extra keys
are ignored, missing and `null` are the same thing, and nothing is
coerced. So a Spec can express "a table whose `a` is a table whose `b`
is a table" — `shape.record({a = shape.record({b = ...})})` — which
would close `cosmic/literal_test.tl:143`–`:145` at the cost of naming
the very nesting under test. That is the cost this slice declines to
pay, for the reason below.

**`assert(v is T, msg)` NARROWS, which decides all seventeen.** The
`Change` below reaches for `is` at every site, and the reason is a
single fact nobody had established: a bare `assert` carrying an `is`
test narrows its subject for the rest of the scope, so a cast can be
replaced by a one-line guard rather than by an `if`-block that would
re-indent the test around it. `is` compiles to a plain runtime type
test, so the guard is not decoration: it CHECKS what the cast merely
asserted, and it names no field the test has not already indexed.

**Four type facts, probe-verified at refinement** against a `--make
build` of `fb2587ad` (scratch file outside the tree, `--check types`,
deleted; the first two were first established at `cd87a765` and
re-verified here):

- `==` accepts `any` on one side, so `decoded.a == 1` needs no cast.
- `>=` does not: `cannot use operator '>=' for types <any type> and
  integer`. Any ordering comparison on a decoded field needs a real
  type behind it. No site in these two files makes one.
- `assert(x is T, msg)` narrows `x` below itself, for `T` =
  `{string: any}`, `{number}`, `{any}`, `{string: boolean}` and
  `string`. So does `if x is T then`. Both compile.
- Indexing an unnarrowed `any` is the error that makes each of these
  sites need SOMETHING: `cannot index key 'a' in variable 'result' of
  type <any type>`, with the checker's own hint being the cast the
  slice is removing.

Two composite forms were probed too, because they are what four of the
sites actually look like: a field pulled off a narrowed table into a
local and narrowed again (`local nested = decoded.nested; assert(nested
is {string: boolean}, ...)`), and a sparse `{any}` array indexed past a
hole and compared to `nil` and to `json.null`. Both compile.

**The ratchet does not have to reach zero — but here it does.**
`_build/casts.tl` gates each file's `as` count against
`_build/casts_baseline.tl`; a count that falls is regenerated with the
command the failure prints (`bin/cosmic --make run _build/casts.tl
--baseline`) and a count that holds needs no change. Because every one
of the 17 takes the guard, both files end with no casts at all and both
rows drop OUT of the baseline rather than going to zero — the same
behaviour `_build/casts_test.tl` reports as `"%s: no casts left
(baseline %d)"`.

## Change

Four outcomes were on the table at intake: a **call change** (`decode`
becomes `decode_object`/`decode_array`), an **`is` narrowing**, a
**`shape.into`**, or **a truer cast reason**. Refinement settled every
one of the 17 sites, and the answer is uniform: **`is` narrowing, at
all seventeen**. The other three are rejected below, once, rather than
per site.

**Why not a call change.** `cosmic/json_test.tl` is the json module's
own test file, and `decode_object` and `decode_array` already have four
dedicated tests of their own — `test_decode_object_typed` (`:22`),
`test_decode_object_wrong_shape` (`:31`), `test_decode_array_typed`
(`:46`) and `test_decode_array_wrong_shape` (`:57`). So swapping the
entry point at `:6` or `:14` would not add coverage; it would DELETE
the only coverage of what bare `decode` returns for an object and for
an array. The same argument holds at `:103`, whose subject is
encode→decode round-tripping over the encoder's own output. The five
null-policy sites pin `decode`'s `null` handling and cannot swap at
all, and `:273` decodes a scalar, which neither narrower entry point
accepts.

**Why not `shape.into`.** Every remaining site is a test whose subject
IS the dynamic value: nesting depth, a tab in a bracket key, an inline
row's layout, a hole in an array. A Spec names the shape, so validating
here would assert the very thing under discovery, and a passing test
would then be proving the Spec rather than the parser.

**Why not a truer reason.** A rewritten `-- cast:` comment is the right
answer only where nothing checks the value. `assert(v is T, msg)`
checks it, in one line, with no `if` block and no re-indentation — so
at every one of these sites a truer reason is available that is not a
comment at all.

**The shape of each edit.** Split the cast line into the bare read plus
a guard on the next line:

```teal
local decoded = json.decode(encoded)
assert(decoded is {string: any}, "expected table")
```

The guard's message is the site's own, listed per site below. Nothing
else in any test body moves.

### `cosmic/json_test.tl` — 10 sites

| line | after | guard message |
| --- | --- | --- |
| 6 | `assert(result is {string: any}, "expected table")` | replaces the existing assert; see below |
| 14 | `assert(result is {number}, "expected table")` | replaces the existing assert; see below |
| 103 | `local decoded = json.decode(encoded)` + guard | `"a decoded object is a table"` |
| 105 | `local nested = decoded.nested` + guard on `{string: boolean}` | `"the nested value decodes to a table"` |
| 174 | guard on `{string: any}` | `"a decoded object is a table"` |
| 186 | guard on `{any}` | `"a decoded array is a table"` |
| 198 | guard on `{any}` | `"a decoded array is a table"` |
| 205 | guard on `{any}` (`arr`) | `"a decoded array is a table"` |
| 208 | guard on `{string: any}` (`obj`) | `"a decoded object is a table"` |
| 273 | guard on `string` | `"a decoded json string is a string"` |

**`:6` and `:14` are the one place an existing assert changes, and the
change is runtime-identical.** Both tests open with a `type()` check
whose only purpose is what the guard now does:

```text
-  local result = json.decode('{"a":1,"b":"hello"}') as {string: any} -- cast: from any
-  assert(type(result) == "table", "expected table")
+  local result = json.decode('{"a":1,"b":"hello"}')
+  assert(result is {string: any}, "expected table")
```

`result is {string: any}` compiles to `type(result) == "table"`, so the
runtime test and the message are both unchanged — the line gains the
narrowing and loses the cast, and nothing is weakened or deleted. Quote
both sides of both pairs in the PR description. At the other eight
sites the guard is a NEW line and no existing assert is touched.

### `cosmic/literal_test.tl` — 7 sites

Every one is `{string: any}` off a value `read` (`:14`) already hands
back as `{string: any}`, so each is one read plus one guard:

| line | subject | guard message |
| --- | --- | --- |
| 143 | `shallow.a` | `"level 2 is a table"` |
| 144 | `a.b` | `"level 3 is a table"` |
| 145 | `b.c` | `"level 4 is a table"` |
| 212 | `got.nested` | `"the nested table survives the round trip"` |
| 251 | `got["a\tkey"]` | `"the tab-keyed entry is a table"` |
| 270 | `got["a.tl"]` | `"the inline row is a table"` |
| 280 | `got["a.tl"]` | `"the empty inline row is a table"` |

### The ratchet

Then run `bin/cosmic --make run _build/casts.tl --baseline` — the exact
command the gate's failure prints — and commit the rewritten
`_build/casts_baseline.tl`. Both rows disappear: `"cosmic/json_test.tl"`
and `"cosmic/literal_test.tl"` are absent from the regenerated file, and
no other row changes.

### Expected lengths

`cosmic/json_test.tl` grows by 8 lines (`:6` and `:14` are net zero,
the other eight gain one line each): 324 → 332, against the 500-line
cap. `cosmic/literal_test.tl` grows by 7: 453 → 460. Both stay under
the cap, and `literal_test` is the tight one at 40 lines of headroom.

## Non-goals

- **Do not change what any test asserts, with the one exception
  `Change` names and quotes.** The null-policy tests
  (`cosmic/json_test.tl:174`–`:208`) and the nesting and bracket-key
  tests (`cosmic/literal_test.tl:143`–`:145`, `:251`) exist to pin
  behaviour that is deliberately dynamic. No assertion is weakened,
  reworded to a shape it did not have, or deleted because a validator
  made it redundant. The exception is `cosmic/json_test.tl:7` and `:15`,
  where `assert(type(result) == "table", "expected table")` becomes
  `assert(result is {string: any} / {number}, "expected table")` —
  runtime-identical (`is` compiles to that same `type()` test) and
  message-identical. Every other guard is an added line beside an
  untouched assert.
- **Do not touch the sibling slice's six files** (`_eval/score_test.tl`,
  `_eval/stage_test.tl`, `_make/pin_test.tl`,
  `cosmic/teal_config_test.tl`, `_tool/doc/index_test.tl`,
  `cosmic/fetch/verbs_test.tl`).
- **Do not touch `cosmic/json.tl`, `cosmic/literal.tl` or
  `cosmic/shape.tl`.** The `json.decode` contract — what it returns and
  how `null_value` behaves — is frozen for this slice; a test that
  reveals a contract problem files an item, it does not fix it here.
- **Do not add a combinator to `cosmic.shape`.** No site in this slice
  reaches for a Spec at all.
- **Do not swap `decode` for `decode_object`/`decode_array` anywhere in
  `cosmic/json_test.tl`**, for the reason `Change` states: the narrower
  entry points have their own four tests, and a swap would delete this
  file's only coverage of bare `decode`.
- **Do not edit `_build/casts_baseline.tl` by hand**; run the regen
  command the gate prints.
- **Do not weaken a gate**: no `.cosmicignore` entry, no coverage
  exclusion, no lint suppression.
- **Do not touch `whilp/cosmopolitan`.**

## Acceptance

All commands run verbatim from the `whilp/cosmic` repo root and write
into no committed file.

- `bin/cosmic --make ci` ends `ci: PASS`.

- `bin/cosmic --make test cosmic/json_test.tl cosmic/literal_test.tl`
  ends `test: PASS (2 files)`.

- **Every cast is gone, and none was replaced by another.**

  ```
  grep -c -- "-- cast:" cosmic/json_test.tl cosmic/literal_test.tl
  ```

  reports `0` for both. Re-measured 2026-08-26 at `fb2587ad`, the same
  command reports 10 and 7, so it discriminates. The narrower
  `grep -c -- "-- cast: .*from any"` reports `0` for both as well —
  every site closed rather than being re-justified.

- **Both rows left the ratchet floor.**

  ```
  grep -c -E '"cosmic/(json|literal)_test\.tl"' _build/casts_baseline.tl
  ```

  reports `0`; today it reports `2`. A file with no casts left drops out
  of the baseline entirely rather than going to zero
  (`_build/casts_test.tl:48`). The floor is the regen command's output,
  never a hand edit.

- **The tree-wide `from any` count fell by exactly 17.**

  ```
  git ls-files '*.tl' | xargs grep -h -- "-- cast: .*from any" | wc -l
  ```

  `main` moves fast under this epic, so the check that survives is the
  DELTA: run the command at the branch's merge base and at its head, and
  the difference is 17. At `fb2587ad` the base number is 76.

- **The guards are real narrowings, not decoration.**

  ```
  grep -c -E 'assert\([a-z_]+ is ' cosmic/json_test.tl cosmic/literal_test.tl
  ```

  reports `10` and `7` — one guard per closed site. Today it reports `0`
  for both. (The pattern anchors on the guard's subject being a plain
  local; a looser `assert(.* is ` also matches five prose messages
  containing the word "is", which is why it is not the check.)

- **No assertion was dropped.**

  ```
  git diff origin/main...HEAD -- cosmic/json_test.tl cosmic/literal_test.tl \
    | grep -c '^-.*assert('
  ```

  is `2`, and both are the `:7`/`:15` `type()` pair `Change` sanctions.
  Quote both sides of both in the PR description, so the reviewer judges
  the rewrite rather than the count. Any third removed `assert(` line is
  a failure.

- **The sibling slice's files and the frozen modules are untouched.**

  ```
  git diff --name-only origin/main...HEAD
  ```

  names exactly `_build/casts_baseline.tl`, `cosmic/json_test.tl` and
  `cosmic/literal_test.tl` — in particular not `cosmic/json.tl`,
  `cosmic/literal.tl`, `cosmic/shape.tl`, nor any of the six files the
  sibling slice owns.

- **Both files stay under the cap.**

  ```
  wc -l cosmic/json_test.tl cosmic/literal_test.tl
  ```

  reports at most `500` for each, and the expected values are `332` and
  `460` (324 and 453 today). `cosmic/literal_test.tl` is the tight one.

## Enablement

No blocker, and nothing left for the implementing session to judge.
What held this item out of `ready` was not a missing mechanism but
seventeen unmade per-site decisions; `Change` now names each site, its
narrowed type and its guard message, so the diff is mechanical.

The one fact a session would otherwise have to discover by trial —
that `assert(v is T, msg)` narrows below itself, so a cast becomes a
one-line guard rather than an `if`-block — is probe-verified in
`Evidence` with the forms each site needs, including the two composite
ones. `is` narrowing itself is AGENTS.md's; the comment-and-prose
standard is `skills/docs-style/SKILL.md`.

The sibling slice (`3IPqUmoU`, the other 21 sites under this parent) is
in `check` as PR #1389. It is deliberately NOT a blocker: the two
slices are file-disjoint except for `_build/casts_baseline.tl`, whose
conflict is the mechanical regen the landing rule already covers — run
the regen command again after merging `main` and commit the result.
