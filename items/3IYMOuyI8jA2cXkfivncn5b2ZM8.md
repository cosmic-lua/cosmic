## Evidence

Measured 2026-09-03 against `origin/main` (`96afd807`); every check
below ran under `o/bootstrap/cosmic`, which IS `bin/cosmic.pin`
(`2026-08-31-a5b36f4`, sha verified by `bin/cosmic`).

The nine rows (`awk -F'\t' '$3=="numeric narrowing"'` over the tsv):
`cosmic/format/init.tl` 141, 142, 162, 163 (`e.y as integer or 0 -- cast: tl declares number`),
`cosmic/_literal_lex.tl` 198, 226, 230, `cosmic/fs/octal.tl:23`,
`cosmic/url.tl:54` (`tonumber(hex, 16) as integer`).

The premise "tl declares number" is false on the pin:

    o/bootstrap/cosmic -e '…read /zip/.types/tl.d.tl…'   → record Error … y: integer  x: integer
    …read /zip/tl.lua…  → tonumber: function(any): number / tonumber: function(any, integer): integer

and the checker assigns `number` to `integer` without a guard:

    local n: number = 3; local j: integer = n            → Type check passed
    local i: integer = tonumber("ff", 16)                 → Type check passed
    (position capture) local k: integer = after           → Type check passed

The four files with every ` as integer` stripped type-check against
the tree unchanged
(`git show origin/main:<f> | sed 's/ as integer//' > x.tl; o/bootstrap/cosmic --check types --include-dir /home/user/cosmic x.tl`
→ `Type check passed` ×4). `docs/design/cast-legality.md:76` agrees:
`| numeric narrowing | 9 | 9 | 0 |` — all nine are casts whose operand
already relates to the target.

So nothing waits on a checker rule or a `bin/cosmic.pin` bump: the
sites close on the release the cold build already uses. No `blocks:`.

## Change

- Delete the cast and its `-- cast:` reason at the nine sites; keep
  the surrounding guard comments (`_literal_lex.tl:214-222`'s BOUNDED
  note stays — the bound is the code, not the cast).
- `_build/casts_baseline.tl`: `cosmic/format/init.tl` 5 → 1,
  `cosmic/_literal_lex.tl` 3 → gone, `cosmic/fs/octal.tl` 1 → gone,
  `cosmic/url.tl` 1 → gone (`bin/cosmic --make run _build/casts.tl --baseline`).
- `docs/design/cast-sites.tsv`: `bin/cosmic --make run _build/cast_sites.tl --reconcile`;
  the class empties, so delete `### numeric narrowing` (`casts.md:261-277`)
  and every prose mention (`git grep -n "numeric narrowing" origin/main -- docs _build`;
  `cast-legality.md` is a dated census and keeps its row).
- `bin/cosmic --make ci` ends `ci: PASS`; `_build/coldbuild_test.tl`
  is the proof the pinned checker accepts the result.

## Non-goals

Whether `number → integer` SHOULD assign unchecked is a tl soundness
question — `tl-numeric-narrowing-patch`; nothing here changes the
checker.
