The compact literal encode pays more for its guard than for its
encoding. Confirmed and quantified 2026-08-26 at main `14ff1d1d`: the
Teal domain walk is **57–61% of `format_compact`'s wall time**, and
`format_compact` costs **2.3–2.5× the raw C encode it wraps**. The
cause is not a walk that fails slowly — `is_compact_writable` already
short-circuits at the first violation — it is that on the SUCCESS
path, which is the common one, the whole value is traversed TWICE:
once by Lua to decide the domain, once by C to write it.

## Measurement

Reproduce with a scratch script outside the tree (do not commit it):
build a table of N string-keyed entries holding mixed scalars, then
time `cosmo.EncodeLua(t, {sorted = true})` against
`require("cosmic._literal_format").format_compact(t)` — the difference
IS the guard, since `format_compact` is the walk, that same
`EncodeLua` call, and one concatenation. Best of five runs of 20
iterations each, `os.clock`:

| payload | C encode | guard + encode | guard alone | pin layout |
|---------|---------|----------------|-------------|------------|
| 153 KB  | 2.43 ms | 5.69 ms        | 3.26 ms (57%) | 11.10 ms |
| 944 KB  | 15.04 ms | 38.10 ms      | 23.06 ms (61%) | 90.78 ms |

`cosmo.EncodeJson` on the same values is 1.28 ms and 11.10 ms — the
scale marker. The ratio is stable across a 6× payload range, so this
is structural, not a fixture artifact.

**The compact writer is still the FAST path** and nothing here says
otherwise: it is 0.42–0.51× the pin layout's Lua assembly, which is
what it exists to beat. The claim is only that it leaves roughly half
of its own time on the table.

## Citations, corrected

The original filing cited the domain walk as
`cosmic/_literal_format.tl:395-407`. That range is `format_compact`
itself. The actual sites:

- `is_compact_writable` — `cosmic/_literal_format.tl:339-362`, the
  recursive `pairs` walk, `MAX_DEPTH` 32.
- `is_compact_string` — `:61-63`, one `s:find("\27", 1, true)` per key.
- `is_compact_scalar` — `:81-92`.
- `format_compact` — `:395-407`, which calls the walk and then
  `cosmo.EncodeLua(value, {sorted = true})`.
- The walk is module-private: `LiteralFormatModule` (`:429-433`)
  exports `format`, `format_compact` and `format_file` only, so
  nothing outside the module can time it directly. Hence the
  subtraction above.

## The fix space, narrowed

The original filing offered "fold the check into the encode pass —
either teach the C encoder to refuse the literal domain's exclusions,
or restructure the walk to short-circuit per table". **The second
candidate is now ruled out**: the walk already short-circuits, and
short-circuiting cannot help a value that is inside the domain, which
is the case that costs the time. What is left:

- **(a) One pass, in C.** Teach `cosmo.EncodeLua` to refuse the
  literal reader's exclusions (byte 27 in a key or string, the
  reserved keys, a non-string key, `math.mininteger`, NaN and the
  infinities, depth past 32) and report which, so cosmic can hand a
  refused value to the pin layout without having pre-walked it. This
  is a `definitions.lua` contract change in whilp/cosmopolitan,
  landed there as its own change per that repo's conventions, then
  consumed here as a pin bump. Highest ceiling — it deletes the whole
  23 ms rather than shrinking it.
- **(b) A cheaper walk, in Teal.** Micro-optimize the three
  predicates. Bounded by construction: the floor is one `pairs`
  traversal of the value in Lua, and the table above says a full C
  encode of the same value costs less than that. Worth sizing before
  committing to it.

Picking between them is this item's remaining decision, and it is not
one a slice may leave open — so the next refinement either decomposes
this into a research slice that sizes (b) against (a)'s ceiling, or
commits to (a) and cuts the cross-repo pair (a whilp/cosmopolitan
slice carrying `--repo`, and a cosmic slice blocked on it).

## Acceptance, whichever lands

- `parse(format(v))` fidelity and the refusal set must not move. The
  strict walk exists because the C encoder spells some values the
  reader refuses; any fold must keep those handed off to the pin
  layout, and `_literal_format_test.tl` is where that is pinned.
- The `optimize` skill's compare gate is the regression acceptance,
  and it can now see this code: `literal_format_floor_compact`
  (`_perf/bench/literal_bench.tl`) landed in #1400 for exactly this
  purpose. Its check parses the result back before probing it, so the
  fidelity bar above is enforced by the scenario itself.
- Note when reading that row: it runs the 100-row `FLOOR` fixture,
  which is far smaller than the payloads measured here. A fold's real
  win will show as a ratio, not as a large absolute number on that
  scenario.
