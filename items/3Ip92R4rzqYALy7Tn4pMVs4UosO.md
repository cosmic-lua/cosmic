## Evidence

Measured 2026-09-03 under the pinned checker (`o/bootstrap/cosmic`,
tl 0.24.8 + `3p/tl/tl_patch/`):

    local n: number = 3
    local j: integer = n                                   → Type check passed

No guard, no cast: `integer` is a subtype of `number` in tl, and the
reverse assignment passes too. That is why the whole "numeric
narrowing" class is deletable today (`respec cn5b`) — and why a
`math.type(x) == "integer"` guard narrows nothing: there is nothing to
narrow into. `tonumber(s, base)` is already declared
`function(any, integer): integer` in the pinned prelude, so that half
of the earlier proposal needs no rule.

A strict rule is a soundness change with an unmeasured blast radius;
the census-first shape exists: `3p/tl/tl_patch/cast.tl` carries a rule
gated behind `COSMIC_CAST_LEGALITY=1` (`cast.tl:18-19`, read once per
site at check time, ungated `--make ci` unaffected) and
`docs/design/cast-legality.md` records what it refuses, joined to
files. D21 governs the patch (literal `find`/`replace` entries with a
`note`, `narrow.tl:28-32`; upstream submission by maturity).

## Change

- `3p/tl/tl_patch/integer.tl`: two entries, both gated behind
  `COSMIC_INTEGER_STRICT=1` read the way `cast.tl` reads its variable:
  1. assigning or passing a `number`-typed value where `integer` is
     declared is refused with `integer-strict: number is not integer`
     unless the operand's type is `integer` (integer literals and
     `//`, `&`, `|`, `~`, `<<`, `>>` results stay integer as tl already
     types them);
  2. `math.type(x) == "integer"` (and `~=` in the else arm) narrows a
     plain-variable `x` from `number` to `integer` inside the guarded
     block — the same fact mechanism `narrow-eq-nil` uses (`narrow.tl:130`).
- `docs/design/integer-strictness.md`: the Method command
  (`COSMIC_INTEGER_STRICT=1 xargs -a <(git ls-files '*.tl' | grep -v /testdata/) o/bin/cosmic --check types --include-dir . 2>&1 | grep -c 'integer-strict:'`),
  the count, and the refusals grouped by file with one line each on
  whether the site is a real `number` (needs a guard or a
  `math.tointeger`) or a tl declaration gap (an API that returns
  `number` for an integral value). Keep it under 200 lines.
- `_build/tl_patch_test.tl` (or the existing patch test the directory
  has — `git ls-files _build | grep -i patch`): one case each way for
  both entries.
- Follow-up items, filed not built: the upstream tl issue for the
  narrowing fact; one item per file group the census says is real.
- `bin/cosmic --make ci` ends `ci: PASS` with the rule OFF; the patch
  applies against the pinned tl or `--make fetch` refuses loudly.

## Non-goals

Not un-gating the rule; not touching any cast (`respec cn5b` deletes
them regardless of this outcome); no `bin/cosmic.pin` bump — a gated
rule changes no in-tree result, so the cold-build rule does not bind.
