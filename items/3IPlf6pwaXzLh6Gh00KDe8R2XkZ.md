## Goal

G3 — an honest type layer, no escape hatches. `cosmic.shape` exists to
turn `from any` casts into one checked decode ([D28](docs/decisions/d28-shape-combinators.md)),
and its own doc comment claims the domain: "a value that comes out of
`json.decode`, `literal.parse`, a loaded chunk or `Response:json()`"
(`cosmic/shape.tl:2-3`). A loaded chunk can hand back a table keyed by
integers; no combinator can describe one, so the claim is not true and
the last two `from any` casts in `_tool/coverage/report.tl` cannot
close. This slice makes the claim true with one combinator, closes both
casts, and amends D28's combinator list so the record and the module
agree.

## Evidence

Measured 2026-08-26 against `origin/main` at `40bed017`.

**The gap.** `cosmic/shape.tl` is 290 lines
(`git show origin/main:cosmic/shape.tl | wc -l`). `walk` dispatches on
`spec.kind` and its two table branches both refuse a sparse
integer-keyed table:

```text
-- cosmic/shape.tl:158
  elseif kind == "list" then
-- cosmic/shape.tl:173
  elseif kind == "map" then
```

`list` (line 158) calls `count_keys` (`cosmic/shape.tl:100`) and
refuses anything whose keys are not exactly `1..n`; `map` (line 173)
refuses any key that is not a string. A hit table like
`{[3] = 7, [9] = 1}` is neither. The combinators are `list`
(`cosmic/shape.tl:212`) and `map` (`:219`), declared on `ShapeModule`
at `:270-271` and bound at `:283-284`.

**The two sites.**

```text
$ grep -n 'cast:' _tool/coverage/report.tl
227:  local t = data as {string: any} -- cast: from any
235:  return hits as {string: {integer: integer}} -- cast: from any
```

Both are in `read_cov` (`_tool/coverage/report.tl`, 467 lines), which
`load`s a `.cov` file in an empty environment and hands back
`{string: {integer: integer}} | nil, string` — a display-path map whose
values are line-number-keyed hit counts. The inner table is written by
the collector through `literal.format` and is exactly the shape neither
combinator admits.

**How rare the shape is.** One cast in the tree names an integer-keyed
table type:

```text
$ git grep -c -E 'as \{[^}]*integer: ' origin/main -- '*.tl'
origin/main:_tool/coverage/report.tl:1
```

against 98 `-- cast: from any` sites overall
(`git grep -c 'cast: from any' origin/main -- '*.tl'`, summed). So this
buys two casts today, not a class — which is why the combinator has to
be the smallest one that fits rather than a general key-spec facility.

**Where it can arise at all.** JSON has no integer keys, so this shape
can only reach `into` from a Lua-valued source: a loaded chunk (the
case above) or `cosmic.literal` once it reads integer bracket keys
(board item 3IOGXIBq, unstarted). That bounds the combinator's audience
and is the honest thing for its doc comment to say.

**The existing diagnostics that must survive.** `read_cov` returns
three error strings of its own — `"empty coverage data"`
(`_tool/coverage/report.tl:225`), `"unsupported coverage data version"`
(`:229`) and `"missing hits table"` (`:233`) — and
`_tool/coverage/report_test.tl:127` (`test_read_cov_rejects_garbage_and_bad_version`)
exercises the version path.

## The shape, decided

**Add one combinator, `shape.integer_map(of)`, symmetric with
`shape.map(of)`.** A table every one of whose keys is an integer and
whose every value has shape `of`. Density is not required — that is
exactly what separates it from `shape.list`.

The name is spelled out per [D20](docs/decisions/d20-naming-charter.md)
and composed from the two names already in the module, `shape.integer`
and `shape.map`; `intmap` would abbreviate and does not read as either.

The alternatives, rejected:

- **A key Spec on `map`** — `shape.map(of, key)` defaulting to
  `shape.string`. More general, and it would also admit a future
  number- or boolean-keyed table. It loses on cost against the one site
  that exists: it changes the signature of a shipped public function,
  needs a new `Spec` field, and makes `map`'s error message
  ("expected map, got a non-string key") either generic or
  key-spec-dependent. D28 rejected data-shaped specs for being
  unchecked by the compiler; a second positional `Spec` is not that, but
  it does move `map` from "one thing" to "one thing plus a mode" to buy
  a generality nothing in the tree asks for.
- **Refuse the shape and leave the two casts justified.** Defensible —
  `-- cast: from any` on a `load`ed table is an honest reason, and two
  casts in internal tooling are not a crisis. It loses because the
  module's own doc comment names "a loaded chunk" as a source it
  serves, so refusing makes the documentation wrong rather than the
  code small; and because the refusal is not a principle anyone could
  restate — "shape describes decoded data, except when the keys are
  integers" is a gap, not a boundary.
- **A `shape.equal(v)` combinator to fold the version check in.** Out
  of scope: `read_cov`'s version test is a value assertion, not a shape
  one, and it stays where it is (below).

## Change

Four files.

**1. `cosmic/shape.tl`.** Mirror the `map` branch:

- In `walk`, a new `elseif kind == "integer_map" then` arm directly
  after the `"map"` arm. Non-table → `mismatch(path, "integer_map", v)`.
  A key that is not an integer (`if not (k is integer) then`) →
  `named(path) .. ": expected integer_map, got a non-integer key"`.
  Each value walks through `walk(v, k, spec.of, index_path(path, k))` —
  `index_path` (`cosmic/shape.tl:82`) already renders an integer key as
  `[k]`, which is how the path should read.
- `local function integer_map(of: Spec): Spec` beside `map`
  (`cosmic/shape.tl:219`), returning `{kind = "integer_map", of = of}`.
- The `ShapeModule` field and the `M` entry, in the same positions
  relative to `map` as `map` holds relative to `list`.
- Doc comments: the combinator's own `---` block says the keys need not
  be dense and that this shape reaches `into` only from a Lua-valued
  source (a loaded chunk, or `literal` if it grows integer bracket
  keys), never from JSON.

`Spec` grows no field, and `optional` (`cosmic/shape.tl:236`) already
copies `kind` and `of`, so `shape.optional(shape.integer_map(...))`
works with no change.

**2. `cosmic/shape_test.tl`** (163 lines today). One `test_*` per
behaviour, each called on the line after its `end`:

- a sparse integer-keyed table validates
- a dense one validates too (it is not a `list`, but it is admitted)
- a string key is refused, and the message names the path
- a fractional-number key is refused
- an element that fails `of` is refused, and the path reads `[k]`
- an integer-keyed table nested under `shape.map` validates
- `shape.optional(shape.integer_map(...))` admits nil
- a non-table is refused with "expected integer_map"

**3. `_tool/coverage/report.tl`.** In `read_cov`, replace both casts
with one validation. The spec is a module-level `<const>`:

```teal
local COV <const> = shape.record({
  version = shape.integer,
  hits = shape.map(shape.integer_map(shape.integer)),
})
```

The three existing diagnostics stay, so the order is: `load`/`pcall`
unchanged; `data == nil` → `"empty coverage data"`; validate `data`
against `COV`; on a validation error return it prefixed the way the
module's other errors are; then the `version ~= 1` test →
`"unsupported coverage data version"`, and return the validated `hits`.
`"missing hits table"` is what a `hits: missing` validation error must
still say — keep the explicit nil test above the validation rather than
letting the message change, because
`_tool/coverage/report_test.tl:127` and the gate's own output read it.
Both `-- cast: from any` comments go with their casts; no new cast
appears.

**4. `docs/decisions/d28-shape-combinators.md`.** An amendment, not a
new record ([D26](docs/decisions/d26-decision-records.md)): the facts
D28 rests on are unchanged and its decision still holds — only its
combinator list moves. Add `shape.integer_map` to decision point 2's
enumeration, and one `rejected:` bullet for the key-Spec-on-`map`
alternative, with the reasoning above. Do not restate D28's context or
touch any other section.

## Non-goals

- **Do not generalize `shape.map`.** Its signature, its `"expected map,
  got a non-string key"` message and its `Spec` shape are unmoved.
- **Do not add any other key kind** — no number-, boolean- or
  arbitrary-key combinator, and no `shape.equal`.
- **Do not change any semantics D28 froze**: extra keys stay ignored,
  nothing is coerced, errors stay plain strings carrying the first
  mismatch, and `into` still returns the same table it was given.
- **Do not change `read_cov`'s signature, its three error strings, or
  the `.cov` file format**, and do not touch `cosmic.literal`'s grammar
  — integer bracket keys there are board item 3IOGXIBq.
- **Do not edit `docs/design/casts.md`.** It declares itself measured at
  `d3e59de7` (`docs/design/casts.md:10`) and its counts describe that
  commit; the `doc-citation` lint treats it as a snapshot and repointing
  it is not this slice's business.
- **Do not close any other `from any` cast.** The other 96 are their own
  board items.
- **Do not supersede D28** or open a new decision record.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/shape_test.tl` ends `test: PASS`.
- `bin/cosmic --make test _tool/coverage/report_test.tl` ends
  `test: PASS`, with `test_read_cov_roundtrip`,
  `test_read_cov_accepts_prefixless_bodies` and
  `test_read_cov_rejects_garbage_and_bad_version` unedited.
- `grep -c 'cast: from any' _tool/coverage/report.tl` reports `0`
  (today `2`), and
  `git grep -c -E 'as \{[^}]*integer: ' -- '*.tl'` reports nothing
  (today one line, `_tool/coverage/report.tl:1`).
- `grep -c 'integer_map' cosmic/shape.tl` reports at least `6` (today
  `0`): the walk arm, the combinator, the record field, the table entry
  and the two messages.
- `grep -n 'shape.integer_map' docs/decisions/d28-shape-combinators.md`
  finds it in decision point 2.
- `wc -l cosmic/shape.tl` reports at most `500` (290 today), and the
  same for `cosmic/shape_test.tl` and `_tool/coverage/report.tl` (163
  and 467 today).
- `git diff --name-only origin/main` lists exactly `cosmic/shape.tl`,
  `cosmic/shape_test.tl`, `_tool/coverage/report.tl`,
  `docs/decisions/d28-shape-combinators.md` — plus `.cosmic-coverage`
  if and only if the coverage ratchet prints the regen command, in
  which case run exactly that command and commit its result.

## Enablement

none needed. `shape.map`'s branch, combinator, record field and table
entry (`cosmic/shape.tl:173`, `:219`, `:271`, `:284`) are the worked
example for all four edits, and `cosmic/shape_test.tl` is the worked
example for the tests. The amendment form is the `decide` skill
(`skills/decide/SKILL.md`), and D28 is the record to amend.
