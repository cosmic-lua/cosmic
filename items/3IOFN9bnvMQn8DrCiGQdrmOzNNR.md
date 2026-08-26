The compact literal encode pays more for its guard than for its
encoding. Confirmed and quantified at main `14ff1d1d`: the Teal domain
walk is **57-61% of `format_compact`'s wall time**, and
`format_compact` costs **2.3-2.6x the raw C encode it wraps**. The
cause is not a walk that fails slowly — `is_compact_writable` already
short-circuits at the first violation — it is that on the SUCCESS
path, which is the common one, the whole value is traversed TWICE:
once by Lua to decide the domain, once by C to write it.

This item is now a container: the fix is **(a) one pass, in C**, and
the two slices under it are the cross-repo pair that delivers it. What
follows is the evidence that picked (a) and ruled (b) out.

## Measurement

Reproduce with a scratch script outside the tree (do not commit it):
build a table of N string-keyed entries holding mixed scalars and one
nested table each, then time `cosmo.EncodeLua(t, {sorted = true})`
against `require("cosmic._literal_format").format_compact(t)` — the
difference IS the guard, since `format_compact` is the walk, that same
`EncodeLua` call, and one concatenation. Best of five runs of 20
iterations each, `os.clock`, `o/bin/cosmic` built from the tree.

Measured 2026-08-26 at main `14ff1d1d` (fixture: 400 and 2500 entries):

| payload | C encode | guard + encode | guard alone |
|---------|----------|----------------|-------------|
| 51 KB   | 0.83 ms  | 2.23 ms (2.69x) | 1.40 ms (63%) |
| 332 KB  | 5.64 ms  | 14.52 ms (2.58x) | 8.89 ms (61%) |

An earlier pass on a different machine measured 153 KB / 944 KB
fixtures at 2.43/5.69 ms and 15.04/38.10 ms — the same 57-61% ratio.
The ratio is stable across machines and a 6x payload range, so this is
structural, not a fixture artifact.

**The compact writer is still the FAST path** and nothing here says
otherwise: it is roughly half the pin layout's Lua assembly, which is
what it exists to beat. The claim is only that it leaves most of its
own overhead on the table.

## Citations

- `is_compact_writable` — `cosmic/_literal_format.tl:339-362`, the
  recursive `pairs` walk, `MAX_DEPTH` 32.
- `is_compact_string` — `:61-63`, one `s:find("\27", 1, true)` per key
  and per string value.
- `is_compact_scalar` — `:81-92`; `is_finite` — `:46-48`.
- `RESERVED` — `:307-314`, the 22 Lua keywords.
- `format_compact` — `:395-407`, which calls the walk and then
  `cosmo.EncodeLua(value, {sorted = true})`.
- The walk is module-private: `LiteralFormatModule` (`:429-433`)
  exports `format`, `format_compact` and `format_file` only, so
  nothing outside the module can time it directly. Hence the
  subtraction above.

## (b) is ruled out, measured rather than argued

The previous revision of this spec asserted that a cheaper Teal walk
was "bounded by construction: the floor is one `pairs` traversal of
the value in Lua, and a full C encode of the same value costs less
than that". **Both halves of that are wrong**, and the correction is
what decides the item. Measured 2026-08-26 on the same fixtures and
harness:

| payload | C encode | current guard | bare `pairs` walk | hand-inlined guard |
|---------|----------|---------------|-------------------|--------------------|
| 51 KB   | 0.83 ms  | 1.40 ms       | 0.34 ms           | 0.91 ms |
| 332 KB  | 5.64 ms  | 8.89 ms       | 2.21 ms           | 5.83 ms |

- A bare recursive `pairs` traversal that touches nothing is **0.39x a
  full C encode**, not more than it. The floor claim was inverted.
- But the floor is not reachable: the guard's cost is the PREDICATES,
  not the traversal. The "hand-inlined guard" column is the same
  domain test with all three predicates written into the loop body,
  `string.find` hoisted to an upvalue instead of a method index, and
  one function call per TABLE instead of three per ENTRY. It verifies
  `true` on the fixture, and it lands at 5.83 ms against the current
  8.89 ms.
- So the realistic (b) takes `format_compact` from 14.52 to 11.46 ms —
  **21% off, 2.58x C down to 2.03x C**. Against (a)'s ceiling of 1.0x
  C, (b) captures roughly a third of the available win while leaving
  the double traversal in place. The residue is `find(k, "\27")` on
  every key and every string value, which no Teal rewrite removes.

Do not re-open (b) as a slice on its own: 21% is real but it is the
smaller half of a change (a) subsumes entirely, and landing it first
would rewrite the very code (a) deletes.

## (a), and why it is shaped as a pair

Teach `cosmo.EncodeLua` to refuse the literal reader's exclusions
itself, so cosmic hands a refused value to the pin layout without
having pre-walked it. The C side already has the machinery: the
encoder carries a `reason` field on `struct Serializer`
(`third_party/lua/cosmo.h:22`) and a `-1` refusal path that surfaces
as `nil, reason` (`third_party/lua/luaencodeluadata.c:437`), and
`LuaEncodeSmth` (`tool/lua/lcosmo.c:105-156`) already reads a boolean
option table, so the flag is ADDITIVE — no existing return shape,
error value or constant moves.

That makes it a `definitions.lua` contract addition in
whilp/cosmopolitan, landed there as its own change per that repo's
conventions, then consumed here as a pin bump — which is exactly the
two slices under this container, the second blocked on the first.

## What ends this container

When both children are done, verify the outcome rather than the
children: re-run the harness above and confirm `format_compact` is
within noise of `cosmo.EncodeLua` on the same value (target: at or
below 1.2x C encode, against 2.58x today), and that
`_literal_format_test.tl` still pins the same refusal set.

## Outcome, measured

Both children landed — `3IRqQvST` as whilp/cosmopolitan #278 (released
`2026.08.26-fe7c36c4c`) and `3IRqU7yQ` as whilp/cosmic #1403. The
harness above was re-run 2026-08-26 at cosmic main `b4ad036b`, with
`o/bin/cosmic` built from that tree, on the same recipe (N string-keyed
entries of mixed scalars plus one nested table each, best of five runs
of 20 iterations, `os.clock`):

| entries | size   | `C(sorted)` | `C(literal)` | `format_compact` | vs `C(sorted)` | vs `C(literal)` |
|---------|--------|-------------|--------------|------------------|----------------|-----------------|
| 400     | 37 KB  | 0.73 ms     | 1.11 ms      | 1.06 ms          | 1.45x          | 0.95x           |
| 2500    | 245 KB | 5.03 ms     | 7.08 ms      | 7.31 ms          | 1.45x          | 1.03x           |

`C(sorted)` is `cosmo.EncodeLua(t, {sorted = true})` — the baseline the
2.58x figure was taken against. `C(literal)` is the call
`format_compact` actually makes today,
`cosmo.EncodeLua(t, {sorted = true, literal = true, maxdepth = 32})`.
The fixture is a little smaller than the original pass (37/245 KB
against 51/332 KB), and the ratio is identical at both sizes, which is
the same stability the original measurement reported across a 6x range.

**The container's problem is solved.** It was that the value is
traversed TWICE on the success path, once by Lua to decide the domain
and once by C to write it. The wrapper is now **0.95x–1.03x of the
encode call it makes** — within noise, which is the outcome test's
primary clause. The 61% guard is gone: 2.58x → 1.45x against the
original baseline, and `_perf`'s `literal_format_floor_compact` scenario
moved −42.7%/−53.9%/−46.5% across three passes on #1403.
`cosmic --make test cosmic/_literal_format_test.tl` → `test: PASS
(1 file)`, so the refusal set is still pinned.

**The 1.2x parenthetical does not hold, and is not this container's to
chase.** `format_compact` is 1.45x `C(sorted)`, not ≤1.2x. The residual
is not a guard and not in Lua: asking the encoder to refuse the reader's
domain costs **~45% more inside C** than not asking
(`C(literal)`/`C(sorted)` = 1.52x at 400 entries, 1.41x at 2500). That
is a different cost with a different cause — the per-value domain check
in `luaencodeluadata.c`, not a duplicated walk — and the 1.2x target was
projected before anyone had measured what the option would cost. Filed
as `3ISDGNep`, under G6 beside this container, rather than reopened here.
