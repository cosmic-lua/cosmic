## Goal

G3 — an honest type layer, via the cast epic's wave 4: the
number-to-integer parse family gets an honest parser instead of a cast.

## Change

Re-measured 2026-08-21 at `aaf4af95` (the census was first taken at
`f420391`; every count below still holds). `git grep -n "tonumber" --
'*.tl' | grep "as integer" | grep -v _test.tl` returns 10 sites, of
which exactly SIX are the prize — a parse with a default where the cast
is pure ceremony:

```
_tool/testrun.tl:232   (tonumber(string.match(got_content, "^(%d+)")) or -1) as integer
_tool/testrun.tl:243   (tonumber(fs.read(base .. ".time") or "") or -1) as integer
cosmic/instrument.tl:162-165   (tonumber(<x>_str) or 0) as integer   (4 sites)
```

1. **`cosmic/string.tl`**: add the parser, fallible-value shape.
   Measured now: `wc -l < cosmic/string.tl` is 431 — 69 lines of
   headroom under the 500-line cap, and this addition is ~22 lines (the
   doc comment, the function, one `StringModule` field, one `M` entry),
   so the file lands near 453 and stays under the cap without a split.
   Place the function after `shell_quote`, the last one defined today
   (it ends at line 385); the `StringModule` record and the `M` table
   both list their members in definition order, so both new entries go
   last.

   ```teal
   --- Parse s as an integer. tonumber's grammar (optional sign,
   --- whitespace tolerated; base 2-36, default 10), judged on the
   --- VALUE rather than the spelling: "1e3" is 1000 and "0x1F" is 31,
   --- while "7.5" is a refusal rather than a truncation.
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

   **The error path must format with `%q`, never with `..`
   concatenation.** Three of the four `instrument.tl` sites hand this
   function a value tl types as `string` that is nil at runtime:
   `parse_line` guards only `op`, `file` and `exit_str`
   (`cosmic/instrument.tl:156`), so `wall_str`, `cpu_str` and
   `maxrss_str` reach lines 163-165 as nil whenever the field is absent,
   and the `or 0` is load-bearing. Measured 2026-08-21 against the
   pinned runtime: `tonumber(nil)` is nil and `("%q"):format(nil)` is
   `nil`, so the base-less call returns the refusal `not an integer:
   nil` cleanly, while `tonumber(nil, 10)` throws `bad argument #1 to
   'tonumber' (string expected, got nil)`. Library code never throws, so
   the base-less path — the only one the six sites use — must stay the
   safe one, and a `..` in the message would throw on exactly these
   inputs.
2. **Migrate the six sites**: `str.to_integer(x) or -1` /
   `... or 0` — the `or` narrows the nil away, so the cast AND its
   justification comment delete. No other call-shape changes. Both
   files need the import added: `_tool/testrun.tl` requires six
   `cosmic.*`/`_tool.*` modules today and not `cosmic.string`;
   `cosmic/instrument.tl` requires `cosmo.unix`, `cosmic.env` and
   `cosmic._fields` and not `cosmic.string`. `cosmic.string` is public
   API (`cosmic.<name>`, no leading `_`), so `_tool/` may require it.
3. **Tests** (`cosmic/string_test.tl`, 221 lines today — ample
   headroom): the rule is the VALUE, not the spelling. Measured against
   the pinned runtime 2026-08-21, so these are the exact expected
   results:

   | call | result |
   |------|--------|
   | `to_integer("42")` | 42 |
   | `to_integer("-17")` | -17 |
   | `to_integer("  42  ")` | 42 (whitespace tolerated) |
   | `to_integer("1e3")` | 1000 (integral VALUE, exponent spelling) |
   | `to_integer("0x1F")` | 31 (hex prefix, DEFAULT base only) |
   | `to_integer("1F", 16)` | 31 |
   | `to_integer("777", 8)` | 511 |
   | `to_integer("0x1F", 16)` | refusal — Lua's `tonumber` rejects the `0x` prefix once a base is given |
   | `to_integer("7.5")` | refusal |
   | `to_integer("nan")` | refusal |
   | `to_integer("")` | refusal |

   Plus one test that a runtime nil earns a refusal rather than a throw,
   which is what keeps the four `instrument.tl` sites honest:
   `str.to_integer(nil as string)` returns nil and a message
   (`-- cast: tl types string.match as string; it is nil at runtime`).
   Also add one `Example_*` in `cosmic/string_example.tl` — a NEW file:
   this module has no example file today.
4. **Baseline regen**: the cast ratchet's failure prints its regen
   command, which is `bin/cosmic --make run _build/casts.tl --baseline`
   (`_build/casts.tl:116`). Run it and commit the regenerated
   `_build/casts_baseline.tl`. Measured today, its affected rows read
   `["_tool/testrun.tl"] = 3` and `["cosmic/instrument.tl"] = 7`; after
   the migration they must read 1 and 3 — the −6 this wave deletes.
   `["cosmic/string_test.tl"]` is 2 today and gains the nil-refusal
   test's cast, so expect it to read 3.

## Non-goals

- the four digit-run casts (`literal.tl:76,108`, `url.tl:54`,
  `fs/octal.tl:23`) STAY: each parses a pattern-verified digit run and
  its justification is honest; migrating them adds dead error branches
  the coverage ratchet would then count unhit.
- the three `math.floor(...) as integer` sites (`instrument.tl:111,
  117,125`) are a different class — whether the pinned tl declares
  `floor(): integer` decides if they simply delete; measure that in a
  later leftovers wave, not here.
- `_tool/testrun.tl:111` (`(128 + r.signal) as integer`) STAYS: it is
  arithmetic on an already-integer field, not a parse, so testrun keeps
  exactly one `as integer` after this wave.
- no changes to `tonumber` semantics beyond the integral-value rule
  stated above; no `cosmic.math` module; no change to the
  `InstrumentData` record's fields or to what `parse_line` returns for
  a line it rejects.

## Acceptance

- `bin/cosmic --make test cosmic/string_test.tl _tool/testrun_test.tl cosmic/instrument_test.tl`
  ends `test: PASS (3 files)`.
- `git grep -c "as integer" -- _tool/testrun.tl cosmic/instrument.tl`
  prints exactly `_tool/testrun.tl:1` and `cosmic/instrument.tl:3` —
  the survivors being `testrun.tl:111` and the three `math.floor`
  sites, both named in Non-goals. (The same command today prints
  `_tool/testrun.tl:3` and `cosmic/instrument.tl:7`.)
- `bin/cosmic --make ci` ends `ci: PASS`, with the regenerated
  `_build/casts_baseline.tl` committed and the new
  `cosmic/string_example.tl` running in its example stage.

## Enablement

none needed — every site is enumerated from a grep re-run 2026-08-21 at
`aaf4af95`, every parse result and the nil-throw hazard are measured
against the pinned runtime and pinned in the tests above, and the
ratchet's own message names the regen command.

## Bounced 2026-08-21: the instrument.tl half needs a decision this spec does not make

Implemented at main `aaf4af95` on branch
`claude/zealous-hypatia-2wmkrz` (commit `0fb9c6b8`, draft PR). Change
items 1, 2 (the two `testrun.tl` sites), 3 and 4 all hold as written —
`--make test cosmic/string_test.tl _tool/testrun_test.tl
cosmic/instrument_test.tl` ends `test: PASS (3 files)`, the grep prints
`_tool/testrun.tl:1` and `cosmic/instrument.tl:3`, and the regenerated
baseline moved exactly the three predicted rows. Two consequences of
the FOUR `instrument.tl` sites were not foreseen:

1. **A bootstrap ordering the spec does not mention.** `cosmic.instrument`
   is on the boot surface, so the pinned release loads it from the tree
   during `--make build`'s generate step while resolving `cosmic.string`
   from its own `/zip/.tl/cosmic/string.tl`. Generation 1 therefore fails
   with `invalid key 'to_integer' in record 'str'`; generation 2, run
   under the binary the first build produced, succeeds. `--make ci`
   converges and is fine, but a bare `--make build` on a COLD tree does
   not — it fails before it can produce the binary that would fix it. Not
   yet measured on a genuinely cold clone; the `repro` CI lane is where
   it would show.
2. **Coverage: the module becomes boot-loaded, and its floor appears to
   drop.** `_make/stamp.tl`'s `stamp_test` demands `cosmic.string` join
   `BOOT_MODULES` (its message names the fix). Once it is boot-loaded,
   `--make coverage` reports `cosmic/string.tl: coverage declined 98.4%
   -> 96.9% (158/163, baseline 180/183)` — the TOTAL moving 183 -> 163
   while the file grew 25 lines, with `local M: StringModule = {` and
   `return M` reported unhit. That is the o/-vs-/zip chunk merge race of
   3ICDL1lV, now confirmed at runtime there. Reverting only the
   `instrument.tl` require clears it.

**The decision to make in this plan pass**, which is why this bounced
rather than shipping: whether wave 4 is the two `testrun.tl` sites
alone (leaving the four `instrument.tl` sites to a later wave, after
3ICDL1lV lands), or whether it waits for 3ICDL1lV. Committing a
`--make coverage --baseline` to absorb the decline is NOT an option
here — it would freeze a measurement artifact as a floor. Mirrored in
`blocked_by` either way.
