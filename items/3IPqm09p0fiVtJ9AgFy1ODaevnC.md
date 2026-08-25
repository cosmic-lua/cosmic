## Goal

G3 — an honest type layer. The other three decoded-data shaping slices
close their casts by making the value arrive typed. **These 17 cannot**:
they sit inside tests whose SUBJECT is the dynamic decode — `json_test`
pins `json.decode`'s null policy and its array/object handling,
`literal_test` proves a deliberately-nested value parses. Swapping in
`decode_object` or validating into a record changes what is under test.
The honest answer is `is` narrowing, which asserts at runtime the very
thing the cast asserted silently.

## Evidence

Measured 2026-08-25 against `e7ac1580`, with
`git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"`. The
counts are unchanged from the parent's `5cd43b78` measurement.

| file | sites | lines |
| --- | --- | --- |
| `cosmic/json_test.tl` | 10 | 6, 14, 103, 105, 174, 186, 198, 205, 208, 273 |
| `cosmic/literal_test.tl` | 7 | 143, 144, 145, 212, 251, 270, 280 |
| **total** | **17** | |

**Why the other mechanisms are wrong here.** `cosmic/json.tl:188-190`
declares `decode: function(str: string, opts?: DecodeOptions): any,
string` beside `decode_object` and `decode_array`, which return
`{string: any} | nil` and `{any} | nil`. `json_test.tl:174`, `:186`,
`:198`, `:205` and `:208` exist to pin what `decode` itself does with
`null` under each `null_value` option; `:6` and `:14` pin that the same
entry point handles an object and an array. Calling `decode_object`
there tests a different function. `literal_test.tl:143-145` walks
`shallow.a.b.c` to prove nesting is accepted, so flattening it into one
validated record removes the assertion.

**Four cast shapes appear**, and `is` covers all four — probe-verified
2026-08-25, type-checks clean and runs:

```text
assert(d is {string: any}, "…")  then d.a       -- yields any
assert(d is {number}, "…")       then d[1] + 1  -- yields number
assert(d is {any}, "…")          then #d
assert(d is string, "…")         then d:upper()
```

The first is the one to watch: after narrowing to `{string: any}` a
FIELD read is still `any`, so a nested site needs a second narrowing
rather than one. `cosmic/json_test.tl:103`/`:105` and
`cosmic/literal_test.tl:143-145` are exactly that shape — two and three
levels — so they become two and three narrowing steps, not one.

AGENTS.md states the rule this slice applies: "Use `is` for dispatch
past nil … also dispatch over `any` (`if v is {string: any} then`)."

**`literal_test.tl:212`, `:251`, `:270` and `:280`** are single-level
reads off a `literal.parse`/`parse_file` result — `got.nested`,
`got["a\tkey"]`, `got["a.tl"]` — one narrowing each.

**Headroom** (`wc -l`, 500-line cap): `cosmic/json_test.tl` 324,
`cosmic/literal_test.tl` 453. `literal_test.tl` has **47 lines of
headroom**, and each `as` replaced by a guard costs a line or two, so
the seven sites there have room only if the guards stay compact —
`assert(x is T, "…")` on one line, never an `if … then … end` block.
If the file would cross 500, say so and stop rather than
`.cosmicignore` it: splitting `literal_test.tl` is its own item.

**The ratchet.** `_build/casts.tl` counts every `as` token per file and
gates it against `_build/casts_baseline.tl`. Today's rows:
`cosmic/json_test.tl` 10, `cosmic/literal_test.tl` 7.

## Change

Replace each of the 17 casts with an `is` narrowing on a local, keeping
the decode call exactly as it is.

1. **`cosmic/json_test.tl`** — at each of the 10 sites, keep the
   `json.decode(...)` call verbatim (including its `opts` argument at
   `:205` and `:208`), then `assert(<local> is <shape>, "<message>")`
   before the first read. Use the shape the cast named: `{string: any}`
   at `:6`, `:103`, `:208`; `{number}` at `:14`; `{any}` at `:186`,
   `:198`, `:205`; `string` at `:273`. `:105` (`decoded.nested as
   {string: boolean}`) is the second level of `:103` and needs its own
   narrowing on the field copied to a local.

2. **`cosmic/literal_test.tl`** — the same, one narrowing per level.
   `:143-145` walks three levels (`shallow.a`, then `.b`, then `.c`),
   so each level is a local plus its own `assert(… is {string: any},
   …)`. `:212`, `:251`, `:270`, `:280` are one level each.

Every added `assert` is a NEW assertion, not a replacement: the tests
gain a runtime check that the decode produced the shape the test then
reads. Give each one a message naming what was expected, in the style
of the asserts already in the file.

Then rewrite the ratchet floor with exactly the command the gate
prints — `bin/cosmic --make run _build/casts.tl --baseline` — and
commit the result. Never hand-edit `_build/casts_baseline.tl`.

## Non-goals

- **Do not change any decode call.** Not the function
  (`decode` stays `decode`), not its arguments, not its `opts`. The call
  is the subject under test; changing it is the one thing that would
  make this diff worthless.
- **Do not weaken or delete a null-policy or nesting assertion.**
  `json_test.tl:174-208` and `literal_test.tl:143-145` are the reason
  this slice exists as its own item.
- **Do not touch any file outside these two.** `3IOeg86u` owns the
  non-test sites, and the sibling test slice owns the other six test
  files — including `_eval/score_test.tl`, which uses a validating
  decode rather than `is`.
- **Do not introduce `cosmic.shape` here.** Validating into a record is
  precisely the mechanism these sites reject.
- **No new `as` cast and no new `-- cast:` line anywhere in the diff.**
  A site that genuinely cannot be narrowed is a finding: leave it, and
  file a capture naming it.

## Acceptance

All commands run verbatim from the repo root.

- `bin/cosmic --make ci` ends `ci: PASS`.

- **The 17 sites are gone.**

  ```
  grep -c -- "-- cast: " cosmic/json_test.tl cosmic/literal_test.tl
  ```

  reports `0` for both (10 and 7 at `e7ac1580`), and

  ```
  git ls-files '*.tl' | xargs grep -h -- "-- cast: .*from any" | wc -l
  ```

  reports exactly **17 fewer** than it did at pull. Re-measure at pull
  and quote both numbers: the bucket is 165 at `e7ac1580`, and two
  sibling slices remove a disjoint 21 each, so the landing order
  decides the absolute figure.

- **The decode calls are byte-identical.**

  ```
  git diff origin/main...HEAD | grep '^-' | grep -c 'json\.decode\|literal\.parse'
  ```

  reports `0`. No removed line may contain a decode or parse call — if
  one does, the call changed, which this slice may not do.

- **No assertion was lost.**

  ```
  grep -c 'assert(' cosmic/json_test.tl cosmic/literal_test.tl
  ```

  reports at least **90** and **108** — the counts at `e7ac1580` — and
  should be higher, since every narrowing adds one.

- **The tests still pass and still test the same thing.**

  ```
  bin/cosmic --make test cosmic/json_test.tl cosmic/literal_test.tl
  ```

  ends `test: PASS (2 files)`.

- **The floor was regenerated, not edited.** After
  `bin/cosmic --make run _build/casts.tl --baseline`,
  `bin/cosmic --make test _build/casts_test.tl` ends `test: PASS`, and
  both rows are gone from `_build/casts_baseline.tl` (a file missing
  from the floor reads as having had none).

- **The file cap still holds.**

  ```
  wc -l cosmic/json_test.tl cosmic/literal_test.tl
  ```

  each ≤ **500**. `cosmic/literal_test.tl` is 453 at `e7ac1580`, so this
  is the bound most likely to bind.

- **No cast was added.**

  ```
  git diff origin/main...HEAD | grep -c '^+.*-- cast:'
  ```

  reports `0`.

## Enablement

No blocker, and no new mechanism: `is` over a decoded `any` is an
existing Teal feature, documented in AGENTS.md's narrowing section and
probe-verified above for all four shapes these files use.

File-disjoint from its sibling slice and from `3IOeg86u`, so the three
can run in any order or at once. The one shared file is
`_build/casts_baseline.tl`: merge the base before regenerating it, or
the floor is written against a stale tree.

Conventions are AGENTS.md; the comment-and-prose standard is
`skills/docs-style/SKILL.md`.
