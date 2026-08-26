## Goal
G3 — an honest type layer. Parent: "casts: the 16 any-map residue".
This is its one site-group that needs a NEW type: the 4 sites where the
formatter walks a tl comment token.

## Evidence

Re-measured 2026-08-26 against `fb2587ad` (`main`); first measured
2026-08-25 at `1f9279ab`, and every line number, count and length below
is the `fb2587ad` one. Measured with
`grep -n -- "-- cast: .*from any" cosmic/format/init.tl` — 4 sites, all
inside `build_items`, all in five consecutive lines:

```
108:        local c = raw_c as {string: any} -- cast: from any
110:          y = c["y"] as integer, -- cast: from any
111:          x = c["x"] as integer, -- cast: from any
112:          tk = c["text"] as string, -- cast: from any
```

`raw_c` is an element of `token.comments`, and the generated `tl.d.tl`
declares `comments: {any}` (`grep -n "comments" o/_types/types_gen/tl.d.tl`
prints `27:    comments: {any}`). The three fields lifted out of it —
`y`, `x`, `text` — are exactly the three fields tl's own `Comment`
record has.

**The generated route IS available here, and this is what separates
this group from the coverage-AST slice (`3IOmhE0Z`, PR #1381).** There,
`_types/gentl.tl` could not carry the record because tl declares its
AST node as `local record Node` at column 0 and `verify_record` only
matches an INDENTED declaration inside `record tl`. `Comment` is the
other case: `grep -n "record Comment" o/3p/tl/tl.tl` prints `694`, and
it is indented inside `record tl` with exactly the fields the formatter
reads and nothing else —

```teal
   record Comment
      x: integer
      y: integer
      text: string
   end
```

— so `verify_record` finds it, every curated field is present in its
own body (no inherited `Where` problem), and the record is small,
stable and genuinely part of the public token interface a `require("tl")`
user already sees through `Token.comments`.

`cosmic/format/init.tl` is 406 lines (`wc -l < cosmic/format/init.tl`),
so 94 lines of headroom under the 500-line cap. The generated route
adds nothing to this file — it SHRINKS it by one line — which is the
capacity argument for preferring it here. `_types/gentl.tl` is 303
lines and takes the 7 the record costs.

The file's other five casts are a different subject and stay:
`:119`'s `token as Item -- cast: parse is done; Item only adds fields`,
and four `e.y`/`e.x` reads at `:142`, `:143`, `:163` and `:164` reasoned
`-- cast: tl declares number`. So the file's `_build/casts_baseline.tl`
row goes 9 → 5, not to zero.

**The three open questions, settled by measurement.** The whole change
below was applied to a scratch checkout of `fb2587ad`, built
(`bin/cosmic --make build`), gated (`bin/cosmic --make ci`) and then
reverted; every number in `Acceptance` is read off that run.

1. **`Token.comments` narrowing is not a tracked surface change, and
   needs no design note.** `_build/public_surface_baseline.tl` is a set
   of MODULE NAMES (`["cosmic.format"] = true`, `["cosmic.teal"] =
   true`), not type signatures: `grep -c 'tl\.'
   _build/public_surface_baseline.tl` reports `0`, so the surface
   ratchet has nothing to say about a field inside the generated
   `tl.d.tl`. Nor is there drift to record — `tl.d.tl` is generated into
   `o/_types/types_gen/` on every build and is not committed. And the
   narrowing is what that file exists to do: its own PRELUDE header
   calls it "the narrowed public tl surface cosmic supports … records
   are curated field subsets verified against upstream". `{any}` was
   never the honest type; the runtime values are tl `Comment` records.
   No `docs/design/` note, no decision record.
2. **The loop head needs no cast.** With `comments: {Comment}`,
   `for _, c in ipairs(token.comments)` yields a plain `Comment` and
   `c.y`, `c.x`, `c.text` read typed. All four casts close and none is
   replaced: measured, `grep -n -- "-- cast:" cosmic/format/init.tl`
   lists only the five unrelated ones after the change.
3. **`:119` is unaffected and stays.** `token as Item` is a
   record-widening cast with its own true reason and no relation to
   `comments`; it moves to `:118` only because the file lost a line.

## Change

Five files.

**1. `_types/gentl.tl`** — three edits, +7 lines (303 → 310):

- `NAMED` (`:26`) gains `Comment = true`, so `erase("{Comment}")`
  returns `"{Comment}"` instead of `"{any}"`.
- `RECORD_FIELDS` (`:180`) gains `Comment = {"x", "y", "text"}`, placed
  alphabetically before its `Token` entry. That is what puts `Comment`
  through `verify_record` (`:134`) on every build, so tl dropping or
  renaming a field fails the build rather than silently widening the
  type.
- `PRELUDE` (`:191`) gains a `record Comment` block with those three
  fields, immediately above `record Token`, and `Token`'s `comments`
  field changes from `{any}` to `{Comment}`.

**2. `cosmic/format/init.tl`** — `build_items`' inner loop loses its
cast line and reads the fields directly, 9 lines becoming 8:

```teal
      for _, c in ipairs(token.comments) do
        items[#items + 1] = {
          y = c.y,
          x = c.x,
          tk = c.text,
          kind = "comment",
        }
      end
```

Nothing else in the file moves.

**3. `_types/gentl_test.tl`** — one line in `test_erasure_rules`'
`cases` table, beside the existing `["{Token}"] = "{Token}"`:

```teal
    ["{Comment}"] = "{Comment}",
```

This is the only thing that pins `Comment`'s membership in `NAMED`;
without it, a future edit that drops the entry silently erases the
record back to `any` and the formatter's casts come back.

**4. `_types/tl_conformance_test.tl`** — one line after
`local _lex_errs: {tl.Error} = lex_errs`:

```teal
local _comments: {tl.Comment} = tokens[1].comments
```

Type-only, like every other line in that file: it fails to compile if
`Comment` stops being reachable as `tl.Comment` or `Token.comments`
stops carrying it.

**5. `_build/casts_baseline.tl`** — `["cosmic/format/init.tl"]` goes
from `9` to `5`. Run exactly the regen command the gate prints and
commit its output; no other row moves.

## Acceptance

All commands run verbatim from the `whilp/cosmic` repo root.

- `bin/cosmic --make ci` ends `ci: PASS`. Its fmt stage over all 527
  files is what proves the formatter's output is byte-identical: this
  changes how comment tokens are TYPED, not how they are emitted.

- **The four sites are gone and nothing replaced them.**

  ```
  grep -c -- "-- cast:" cosmic/format/init.tl
  ```

  reports `5`; today it reports `9`. The five that remain are `:119`'s
  `token as Item` and the four `-- cast: tl declares number` reads, none
  of them `from any`:

  ```
  grep -c -- "-- cast: .*from any" cosmic/format/init.tl
  ```

  reports `0`; today it reports `4`.

- **The generated type carries the record.**

  ```
  grep -n 'comments' o/_types/types_gen/tl.d.tl
  ```

  prints `comments: {Comment}`; today it prints `comments: {any}`. And

  ```
  grep -c 'record Comment' o/_types/types_gen/tl.d.tl
  ```

  reports `1`; today `0`.

- **The ratchet floor was regenerated, not edited.**

  ```
  grep -n '"cosmic/format/init.tl"' _build/casts_baseline.tl
  ```

  reports `= 5`; today `= 9`. No other row changes.

- `bin/cosmic --make test _types/gentl_test.tl
  _types/tl_conformance_test.tl cosmic/format/init_test.tl` ends
  `test: PASS`, and `_types/gentl_test.tl` reports 2 test functions,
  `_types/tl_conformance_test.tl` 3.

- **Nothing outside the five files moved.**

  ```
  git diff --name-only origin/main...HEAD
  ```

  names exactly `_build/casts_baseline.tl`, `_types/gentl.tl`,
  `_types/gentl_test.tl`, `_types/tl_conformance_test.tl` and
  `cosmic/format/init.tl` — in particular no pin, no
  `docs/design/casts.md`, and nothing under `o/`.

- **Every file stays under the cap.**

  ```
  wc -l _types/gentl.tl _types/gentl_test.tl \
    _types/tl_conformance_test.tl cosmic/format/init.tl
  ```

  reports at most `500` for each; the expected values are `310`, `47`,
  `139` and `405` (from 303, 46, 138 and 406).

## Enablement

No blocker, and nothing left for the implementing session to judge: the
three questions the item opened with are answered above from a build
that was actually made and gated, and `Change` names each edit's file,
position and text. `verify_record` (`_types/gentl.tl:134`) is what keeps
the curated record honest against the pin, and the `Token` entry beside
it is the worked example for all three `gentl` edits. The comment-and-
prose standard is `skills/docs-style/SKILL.md`.

## Non-goals

- **Do not change the formatter's output.** It is frozen: `cosmic
  --check fmt` must format the tree byte-identically before and after,
  which is what `--make ci`'s fmt stage over all 527 files already
  proves. This changes how comment tokens are TYPED, not how they are
  emitted, and no rule in `cosmic/format/rules.tl` is touched.
- **Do not bump the tl pin**, and do not change `gentl`'s erasure rules
  beyond adding `Comment` to the tables that name records — `erase`
  itself (`_types/gentl.tl:31`) is unmoved.
- **Do not touch the other five casts in `cosmic/format/init.tl`.**
  `:119`'s `token as Item` and the four `-- cast: tl declares number`
  reads are a different subject and keep their lines and their reasons.
- **Do not add any other record to `tl.d.tl`.** `Comment` is the one
  this slice needs; the coverage-AST case stays where it is
  (`3IOmhE0Z`), unreachable for the reason `Evidence` states.
- **Do not edit `_build/casts_baseline.tl` by hand**; run exactly the
  regen command the gate's failure message prints (`bin/cosmic --make
  run _build/casts.tl --baseline`) and commit the result.
- **Do not weaken a gate** any other way: no `.cosmicignore` entry, no
  coverage exclusion, no lint suppression.
- **Do not edit `docs/design/casts.md`** — it is a stale snapshot,
  tracked as `3IQC4GeO`.
- **Do not touch `whilp/cosmopolitan`.**
