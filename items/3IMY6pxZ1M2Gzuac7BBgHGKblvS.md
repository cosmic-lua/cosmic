## Goal

G5 — adversarial verification. A fuzz bound that outlives its defect is
a permanently blinded property: `_fuzz/json_fuzz_test.tl` stops drawing
floats above ~1e15, so the whole `[2^53, 2^63)` band the old C encoder
mishandled is unfuzzed. Both of the bound's retirement conditions now
hold, and retiring it is what turns the upstream fix into restored
coverage.

## Evidence

Measured 2026-08-24 against `dba8e5de` (the tree `main` carries after
#1363 landed), with the pinned cosmos built into `o/3p/cosmos/lua`.

**Both blockers are cleared.** Board item `3IHHK1Bj` (whilp/cosmopolitan
PR #273) landed the encoder rule — a Lua float always encodes to a token
carrying `.` or an exponent — and `3p/cosmos/cosmos_pin.tl` already
pins `2026.08.24-354c17e08`, which carries it. The reproduction from
that item's spec, re-run verbatim, now passes where it used to fail:

```
$ o/3p/cosmos/lua -e 'local c=require"cosmo"
  local x=1.775015055792255e18
  local b=c.DecodeJson(c.EncodeJson(x))
  print(c.EncodeJson(x), x==b, math.type(b))
  print(c.EncodeJson(0.0), c.EncodeJson(5.0), c.EncodeJson(1.5))'
1775015055792255000.0	true	float
0.0	5.0	1.5
```

**The bound, as the tree holds it today:**

```
$ wc -l _fuzz/json_fuzz_test.tl
173 _fuzz/json_fuzz_test.tl
$ grep -n '2\^53\|random_float\|deep\.equal' _fuzz/json_fuzz_test.tl
16:--- Generated integers are drawn from [-2^53, 2^53].
26:-- 1. floats are bounded below 2^53 because the C encoder serializes a
55:--- Draw a finite float, spread across magnitudes but kept below 2^53
60:--- @return number A finite float with |v| < 2^53
61:local function random_float(src: source.Recorder): number
79:    return random_float(src)
152:        if not deep.equal(decoded, expected) then
$ sed -n '62p' _fuzz/json_fuzz_test.tl
  return (src:float() * 2.0 - 1.0) * 10.0 ^ src:int(-30, 15)
```

The comment block at `:24-34` introduces itself as "Two domain bounds
below are deliberate"; bound 1 is the float ceiling with its retirement
condition, bound 2 is the ASCII string alphabet, which is the module's
contract and stays.

**The widened domain round-trips, by value and by type.** 200,000
samples drawn as `(rand*2-1) * 10.0^rand(-300,300)`, plus 100,000 drawn
uniformly from the formerly blinded `[2^53, 2^63)` band, encoded and
decoded through the pinned `cosmo` — zero value mismatches and zero
`math.type` mismatches in either sweep. Through the `cosmic.json`
wrapper, 50,000 mixed values (integers in `[-2^53, 2^53]`, floats at
`10.0^rand(-300,300)`, and nested tables carrying both plus a
`[2^53, 2^62)` integral float), compared for value AND `math.type` at
every number: 0 mismatches.

**`deep.equal` cannot see the type half** — it is the value comparison
only, so a silent float-to-integer decode would still pass it:

```
$ o/bin/cosmic -e 'local d=require("cosmic.deep") print(d.equal(5.0, 5), d.equal({a=5.0},{a=5}))'
true	true
```

That is why the type assertion below is a separate walker in this file
rather than a change to `deep.equal`.

**Baseline run:**

```
$ FUZZ_ITERS=2000 o/bin/cosmic --make test _fuzz/json_fuzz_test.tl
1 checks: 1 passed
test: PASS (1 file)
```

## Change

One file: `_fuzz/json_fuzz_test.tl` (173 lines today, 327 of headroom
under the 500-line cap).

**1. Widen the float generator.** At `:62`, change the exponent draw
from `src:int(-30, 15)` to `src:int(-300, 300)`, leaving the mantissa
expression as it is. The measured sweep above is exactly this
expression; 300 is chosen because `|mantissa| < 1` keeps the product
strictly inside the finite double range at both ends, and the sweep
found no mismatch there.

**2. Retire the comment that recorded the bound.** In the block at
`:24-34`, delete the numbered entry for the float ceiling and its
retirement condition — the whole of what is items 1 above — and keep
the ASCII-string entry, rewritten as the single remaining bound so the
lead-in no longer says "Two". Nothing may still reference
`whilp/cosmopolitan#265`. Update `random_float`'s own doc comment at
`:55-60`: it must no longer claim `|v| < 2^53`; say instead that the
draw spans the finite double range and that an integral float above
`2^53` is deliberately in the domain because the encoder now round-trips
it. `INT_LIMIT` and its comment at `:16-17` are untouched (see
Non-goals).

**3. Assert the type half in the round trip.** Add one local helper
above `test_round_trip`:

```
--- @param decoded any The value decode returned
--- @param expected any The value it was encoded from
--- @return boolean Whether every number matches in math.type
--- @return string Which pair did not
local function number_types_match(decoded: any, expected: any): boolean, string
```

It walks the two values in parallel — for a pair of numbers it requires
`math.type(decoded) == math.type(expected)` and returns `false` with a
message naming both types when they differ; for a pair of tables it
recurses over `pairs(expected)` into `decoded[k]`; anything else returns
`true`, because `deep.equal` has already established the shapes agree.
Use `type(v) == "number"` / `type(v) == "table"` for the dispatch if
Teal's `is` will not narrow `any` to `number` here.

In `test_round_trip`'s `check` (`:152`), after the existing `deep.equal`
branch, call it and return its `false, msg` when it fails. The existing
`decode failed` and `decoded value differs` branches and their messages
are unchanged.

## Non-goals

- **`INT_LIMIT` stays at 2^53.** The integer draw's bound is not the
  defect's bound and this slice does not touch `:16-17` or `:77`. Widening
  it is a different question and, if it is worth asking, a different item.
- **Do not touch the ASCII string bound** (`STRING_ALPHABET`,
  `random_string`, `random_char`) — bound 2 is the module's contract.
- **Do not change `cosmic/deep.tl`.** `deep.equal` compares values and
  keeps doing exactly that; every other caller depends on it. The type
  assertion lives in this fuzz module.
- **Do not touch `cosmic/json.tl`, `_fuzz/driver.tl`, `_fuzz/source.tl`**
  or any other `_fuzz/*_fuzz_test.tl`.
- **Do not add NaN or infinity to the generator** — encode rejects them
  by contract, and they belong to the mutation property, exactly as the
  existing `random_float` doc comment says.
- **Do not bump `3p/cosmos/cosmos_pin.tl`.** The pin in the tree already
  carries the fix; a bump inside this diff would confound it.
- **Do not change the `decode_totality` or `mutation_survival`
  properties**, their generators, or `MAX_INPUT_LEN`.

## Acceptance

All commands run verbatim from the repo root and write no committed file.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `FUZZ_ITERS=2000 bin/cosmic --make test _fuzz/json_fuzz_test.tl` ends
  `test: PASS (1 file)` (it does today, at the old bound).
- `FUZZ_ITERS=20000 FUZZ_SEED=1 bin/cosmic --make test
  _fuzz/json_fuzz_test.tl` ends `test: PASS (1 file)` — the widened
  domain is exercised hard enough that the formerly blinded band is
  drawn many times over.
- `grep -cF 'src:int(-300, 300)' _fuzz/json_fuzz_test.tl` is 1 (0 today).
- `grep -cF 'src:int(-30, 15)' _fuzz/json_fuzz_test.tl` is 0 (1 today).
- `grep -cF 'cosmopolitan#265' _fuzz/json_fuzz_test.tl` is 0 (1 today).
- `grep -cF 'Two domain bounds' _fuzz/json_fuzz_test.tl` is 0 (1 today).
- `grep -c '2\^53' _fuzz/json_fuzz_test.tl` is 2 (4 today) — only
  `INT_LIMIT`'s own comment and `random_float`'s new doc comment may
  still name it. (Corrected at pull time: this bound was first written as
  1, which contradicted the `Change` above — that section requires
  `random_float`'s doc comment to say an integral float above `2^53` is
  deliberately in the domain. Retiring the BOUND is the goal; the number
  may still be named where it explains what is now included.)
- `grep -cF 'math.type' _fuzz/json_fuzz_test.tl` is at least 1 (0 today).
- `git diff --name-only main` names exactly `_fuzz/json_fuzz_test.tl`
  and, if the coverage ratchet demands it, `.cosmic-coverage`.
- `wc -l _fuzz/json_fuzz_test.tl` is ≤ 210 (173 today; the cap is 500 and
  this bound is the slice's own).
- **The type assertion discriminates**, shown by a temporary sabotage
  that is then reverted. Insert two lines at the top of
  `test_round_trip`'s `check` body — `local decoded_probe: any = 5.0`
  and `local expected_probe: any = 5` — and call
  `number_types_match(decoded_probe, expected_probe)`, returning its
  `false, msg`. `FUZZ_ITERS=2000 bin/cosmic --make test
  _fuzz/json_fuzz_test.tl` must then FAIL, naming the two `math.type`s
  in its message; revert the three lines and it must end `test: PASS (1
  file)` again. Quote both outputs in the PR. `deep.equal(5.0, 5)` is
  `true`, so this pair is exactly the bug the walker exists to catch and
  the value comparison cannot.
- If `--make ci`'s coverage ratchet fails on the changed file, run
  exactly the regen command its failure message prints
  (`--make coverage --baseline`), commit the result, and say in the PR
  how many rows it lowered. That is the only sanctioned way this diff
  touches a committed baseline.

## Enablement

none needed. Both blockers are cleared and verified in the tree rather
than assumed: the pinned cosmos was executed and the old reproduction
now passes. The widened domain and the type assertion were both measured
end to end through `cosmic.json` before this spec asserted them, and
`deep.equal`'s blindness to `math.type` was demonstrated rather than
inferred, which is what makes the third change a stated pick and not a
hidden decision. The file has 327 lines of headroom, and the properties'
runner (`_fuzz/driver.tl`) needs no change: `FUZZ_ITERS` and `FUZZ_SEED`
already parameterize the run.
