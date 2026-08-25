## Goal
G3 — an honest type layer, no escape hatches. This item's parent is
"casts: close the 61 decoded-data shaping from-any sites", and this is
the mechanism its other two children consume: nothing in the tree turns
a decoded value into a declared record with the fields checked, so every
field read off decoded data costs a cast today.

## Change
Add `cosmic/shape.tl` (public API `cosmic.shape`), `cosmic/shape_test.tl`,
`cosmic/shape_example.tl`, and the decision record `docs/decisions/d28-<slug>.md`.
Convert no call sites — the sibling items own those.

**The API.** A combinator that builds a runtime `Spec`, plus one
generic entry point that validates and hands the value back typed:

```teal
local record Spec end          -- opaque to callers

shape.string:   Spec
shape.number:   Spec
shape.integer:  Spec
shape.boolean:  Spec
shape.any:      Spec
shape.list:     function(of: Spec): Spec
shape.map:      function(of: Spec): Spec
shape.record:   function(fields: {string: Spec}): Spec
shape.optional: function(of: Spec): Spec

shape.into: function<T>(value: any, spec: Spec): T | nil, string
```

`into` walks `value` against `spec` and returns `nil, <path>: <problem>`
on the first mismatch, or the value itself typed as `T`. It returns the
SAME table, not a copy.

**Combinators, not a table of type-name strings.** A spec written as
`{a = "string", b = "number?"}` is data the checker cannot check: a
misspelled type name or a stray key is a runtime error at best and a
silently-skipped field at worst. Every combinator above is a typed
value, so `shape.strng` and a spec key that is not a `Spec` are compile
errors. That is the tradeoff the decision record carries, and its
`rejected` section must state the string-table form and the cost of
picking combinators (verbosity at every spec).

**T comes from the caller's annotation.** Verified against the pinned
release (`bin/cosmic --check types` on a scratch file, 2026-08-25):
three call shapes infer `T` and one does not.

```teal
-- library: a function declared `T | nil, string` returning it directly
return shape.into(raw, SPEC)                              -- works
-- a local with its error
local m, err: Meta | nil, string = shape.into(raw, SPEC)  -- works
-- tests
local m: Meta = check.must(shape.into(raw, SPEC))         -- works
local m = check.must(shape.into(raw, SPEC))               -- FAILS:
                          -- "cannot infer declaration type"
```

The module's doc comment must show all four lines, the failing one
included with the error it produces. Two sibling items convert 61 sites
against this API and will hit the fourth shape.

**Settled semantics, to state in the module doc comment and pin with a
test each:**
- Extra keys the spec does not name are IGNORED. A decoded payload that
  grows a field must not start failing.
- A missing key and an explicit JSON `null` are the same thing: both
  decode to nil, and `shape.optional` is what admits either.
- `shape.integer` accepts a number with no fractional part and stores
  `math.tointeger` of it; a fractional number is a mismatch.
- `shape.map(of)` checks every value against `of` and accepts any string
  key; `shape.list(of)` checks `ipairs` order and rejects a non-list.
- `shape.any` accepts any non-nil value; wrap it in `shape.optional` to
  admit nil.
- Errors are plain strings carrying a dotted path with `[i]` for list
  indices (`"rows[2].silent_bugs: expected number, got string"`), the
  first mismatch only. No structured `Failure` record.
- Validation is recursive and total over what the spec names: nothing is
  checked shallowly and nothing below a named field is left unchecked.

**The record.** `docs/decisions/d28-<slug>.md` in the four-section form
(`skills/decide/SKILL.md`), H1 exactly `# D28 — <claim, lowercase>`, and
the derived table in `docs/decisions/README.md` gains its row — that
file is 64 lines today and `D27` is its last row, so the new row is
appended.

## Non-goals
- No call-site conversions. The 61 `from any` sites under this item's
  parent belong to its two sibling items; a validator that lands in the
  same PR as its first consumer proves nothing.
- No change to `json.decode`, `json.decode_object`, `json.decode_array`,
  `literal.parse`, or `Response:json()` — their signatures and return
  contracts are frozen here. `cosmic/json.tl` is not touched.
- No structured `Failure` error record (D24). A path-and-problem string
  is the contract; `check.must` already accepts it.
- No coercion. `shape.number` does not accept `"1"`, and nothing in this
  module converts between types except `shape.integer`'s
  `math.tointeger`.
- No spec derived from a Teal record declaration. Reading `cosmic/_teal_ast.tl`
  to generate a `Spec` from a record is a separate idea and out of scope.
- No new `docs/guides/**` chapter; `cosmic --docs shape` derives from the
  module's own doc comments.
- No `cosmo.*` C-boundary change.

## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/shape_test.tl` passes, and its cases
  cover, one each: a valid flat record; a wrong-typed field naming its
  path; a missing required field; `shape.optional` admitting both a
  missing key and a nil-valued one; an ignored extra key;
  `shape.integer` accepting `3.0` and rejecting `3.5`;
  `shape.list` rejecting a non-list and naming a bad element's index;
  `shape.map`; `shape.any`; and a two-level nested mismatch whose error
  carries the full dotted path.
- `bin/cosmic --make example cosmic/shape_example.tl` passes.
- `bin/cosmic --make build && o/bin/cosmic --docs shape` prints the
  module reference including `into` and every combinator.
- `wc -l cosmic/shape.tl` is at most 300.
- `grep -c -- "-- cast: " cosmic/shape.tl` is exactly 1 — the sole cast
  is `value as T` after validation; every type test inside the walk uses
  `is` narrowing.
- `bin/cosmic --make test _build/docs_test.tl` passes with the D28 row
  committed in `docs/decisions/README.md`.
- The casts baseline gains its row for `cosmic/shape.tl`: run exactly the
  regen command the gate's failure message prints and commit the result.
  No gate is weakened any other way.

## Enablement
No blocker items — nothing must land first.

The enablement check found one predicted wrong turn, and it is not
mechanizable in core: a session converting a test site will reach for
`local m = check.must(shape.into(raw, SPEC))`, the shape Teal cannot
infer, and get "cannot infer declaration type" with no hint that an
annotation on the local fixes it. Teal's inference is upstream (D5,
D21) and this is not a narrowing gap, so a checker change is not
available. The countermeasure is docs at the point of use: the four call
shapes above, the failing one included with its exact error, live in
`cosmic/shape.tl`'s module doc comment, which is what `cosmic --docs
shape` serves to the sessions that will hit it.
