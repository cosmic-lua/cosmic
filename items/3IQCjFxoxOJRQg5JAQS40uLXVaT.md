## Goal
G3 — an honest type layer. Parent: "casts: the 16 any-map residue".
This is its one site-group that needs a NEW type: the 4 sites where the
formatter walks a tl comment token.

## Evidence

Measured 2026-08-25 against `1f9279ab` with
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
adds nothing to this file, which is the capacity argument for
preferring it here.

## Direction, not a decision

Add `Comment` to `_types/gentl.tl` — `RECORD_FIELDS`, `NAMED`, and the
`PRELUDE` text — and narrow `Token.comments` from `{any}` to
`{Comment}`; then read `c.y`, `c.x`, `c.text` in `build_items` with no
cast. Refinement must settle:

- Whether narrowing `Token.comments` is a public-surface change that
  needs its own justification. `tl.d.tl` is what user scripts see for
  `require("tl")`; the field goes from `{any}` (accepts anything) to
  `{Comment}` (a record), which can break a user script that assigned
  into it. Check `_build/public_surface_baseline.tl` and decide whether
  the narrowing needs a note in `docs/design/` or is simply an honest
  type nobody could have relied on.
- Whether `raw_c` still needs one cast at the loop head, or whether the
  narrowed `{Comment}` makes `for _, c in ipairs(token.comments)` yield
  a plain `Comment`. Measure, do not assume.
- Whether the adjacent `token as Item -- cast: parse is done; Item only
  adds fields` at `:119` is affected. It is a different reason and
  probably stays; the spec must say which.

## What this must not do

The formatter's output is frozen: `cosmic --check fmt` must format the
tree byte-identically before and after, which is what `--make ci`'s fmt
stage over all 527 files already proves. This changes how comment
tokens are TYPED, not how they are emitted.

No tl pin bump. No change to `gentl`'s erasure rules beyond adding
`Comment` to the tables that name records.

The closure diff lowers the affected row in `_build/casts_baseline.tl`:
run exactly the regen command the gate's failure message prints
(`bin/cosmic --make run _build/casts.tl --baseline`) and commit the
result; no gate is weakened any other way. Leave `docs/design/casts.md`
alone — it is a stale snapshot, tracked as `3IQC4GeO`.
