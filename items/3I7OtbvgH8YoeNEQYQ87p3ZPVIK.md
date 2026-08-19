> Capture note, 2026-08-19: attach under 3HyArM3A (the G3 cast epic)
> when a plan slot opens; specced to the ready bar below.

## Goal

G3 — an honest type layer, via the cast epic's wave 4: the
number-to-integer parse family gets an honest parser instead of a cast.

## Change

The census's "~37 hex/decimal/%d sites" has shrunk, measured 2026-08-19
at `f420391`: 10 `tonumber(...) ... as integer` sites remain, of which
exactly SIX are the prize — a parse with a default where the cast is
pure ceremony:

```
_tool/testrun.tl:232   (tonumber(match) or -1) as integer
_tool/testrun.tl:243   (tonumber(read) or -1) as integer
cosmic/instrument.tl:162-165   (tonumber(s) or 0) as integer   (4 sites)
```

1. **`cosmic/string.tl`**: add the parser, fallible-value shape:

   ```teal
   --- Parse s as an integer. tonumber's grammar (optional sign,
   --- whitespace tolerated; base 2-36, default 10), but the result
   --- must be integral: "7.5" and "1e3" are refusals, not truncations.
   --- @param s string The text to parse
   --- @param base integer? The base, default 10
   --- @return integer | nil The parsed integer
   --- @return string Error message when s is not an integer in base
   local function to_integer(s: string, base?: integer): integer | nil, string
   ```

   Implementation: `tonumber(s, base)`, then `math.tointeger` on the
   result; either failing returns
   `nil, ("not an integer%s: %q"):format(base and " in base "..base or "", s)`.
   NOT `math.tointeger` bare — its tl declaration swallows nil (the
   census's fine print), which is the whole reason this function exists.
2. **Migrate the six sites**: `str.to_integer(x) or -1` /
   `... or 0` — the `or` narrows the nil away, so the cast AND its
   justification comment delete. No other call-shape changes.
3. **Tests** (`cosmic/string_test.tl`): decimal, negative, base 16,
   base 8, refusals ("7.5", "1e3" — yes, tonumber accepts 1e3 as 1000.0
   and to_integer must refuse it as non-integral... measured decision:
   REFUSE, integral VALUE is not integral TEXT — actually 1e3 IS
   integral-valued; the rule is the VALUE: math.tointeger(1000.0)
   succeeds, so "1e3" parses to 1000. Pin exactly that), whitespace,
   empty string, plus one Example in `string_example.tl`.
4. **Baseline regen**: the ratchet's failure prints the command; commit
   the regenerated `_build/casts_baseline.tl` (expected: −6 rows'
   worth from the two files).

## Non-goals

- the four digit-run casts (`literal.tl:76,108`, `url.tl:54`,
  `fs/octal.tl:23`) STAY: each parses a pattern-verified digit run and
  its justification is honest; migrating them adds dead error branches
  the coverage ratchet would then count unhit.
- the three `math.floor(...) as integer` sites (`instrument.tl:111,
  117,125`) are a different class — whether the pinned tl declares
  `floor(): integer` decides if they simply delete; measure that in a
  later leftovers wave, not here.
- no changes to `tonumber` semantics beyond the integral-value rule
  stated above; no `cosmic.math` module.

## Acceptance

- `bin/cosmic --make test cosmic/string_test.tl _tool/testrun_test.tl cosmic/instrument_test.tl`
  ends `test: PASS (3 files)`.
- `git grep -c "as integer" -- _tool/testrun.tl cosmic/instrument.tl`
  counts only the three floor sites (instrument) and zero in testrun.
- `bin/cosmic --make ci` ends `ci: PASS` with the regenerated baseline
  committed.

## Enablement

none needed — the sites are enumerated from today's grep, the
integral-value decision is pinned in the tests, and the ratchet's own
message names the regen command.
