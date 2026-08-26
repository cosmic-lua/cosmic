## The finding

`cosmo.EncodeLua`'s `literal = true` option costs **~45% more inside C**
than the same call without it. It is the residual overhead left after
`3IOFN9bn` deleted the Teal guard walk: the wrapper is now within noise
of the encode call it makes, so all of `format_compact`'s remaining
1.45x over a plain `sorted = true` encode is C-side domain checking.

Measured 2026-08-26 at cosmic main `b4ad036b`, with `o/bin/cosmic` built
from that tree, using `3IOFN9bn`'s own harness recipe (N string-keyed
entries of mixed scalars plus one nested table each, best of five runs of
20 iterations, `os.clock`, script kept outside the tree):

| entries | size   | `C(sorted)` | `C(literal)` | `format_compact` | literal tax |
|---------|--------|-------------|--------------|------------------|-------------|
| 400     | 37 KB  | 0.73 ms     | 1.11 ms      | 1.06 ms          | 1.52x       |
| 2500    | 245 KB | 5.03 ms     | 7.08 ms      | 7.31 ms          | 1.41x       |

`C(sorted)` is `cosmo.EncodeLua(t, {sorted = true})`; `C(literal)` adds
`literal = true, maxdepth = 32`, which is exactly what
`cosmic/_literal_format.tl`'s `format_compact` passes. The Lua wrapper
around `C(literal)` is 0.95x–1.03x of it — nothing left on that side.

This is a hypothesis, not a diagnosis: nobody has profiled which part of
the check costs the 45%. The candidates visible from the source landed in
whilp/cosmopolitan #278 are a per-key reserved-word lookup, a per-string
scan for byte 27, and a per-value type/finiteness test — all on the hot
serializer path, all skipped entirely when `literal` is off.

## Why it is worth an item

`literal.format(..., {layout = "compact"})` is the writer behind every
committed floor and every machine-read literal file cosmic produces
(D27), so this is a G6 defining path with a gate already on it —
`_perf/bench/literal_bench.tl`'s `literal_format_floor_compact` scenario,
landed in #1400. A win here shows up on that row with no new harness to
build.

## What a slice under this would have to establish first

The 45% is measured at the binding boundary, not attributed. Before any
change, a slice needs a profile of `LuaEncodeSmth`/`luaencodeluadata.c`
under `literal = true` against the same fixture — `o//tool/lua/lua.dbg`
is a plain ELF with symbols and `perf record`/`perf report` work on it
directly (whilp/cosmopolitan AGENTS.md) — naming which of the three
candidates above dominates. Optimizing before that is guessing.

The wall that binds any such slice: the binding contract is frozen. The
domain `literal = true` refuses is now consumed by
`cosmic/_literal_format.tl` and pinned by
`cosmic/_literal_format_test.tl`; a faster check that admits or refuses
one value differently is a correctness regression in the corrupting
direction, not an optimization. `3IRqU7yQ` measured the domains agreeing
on 35 of 36 cases and that equivalence is the thing to preserve.

## Provenance

Surfaced by the `3IOFN9bn` container outcome check, which found its
primary clause held (the wrapper is within noise of its encode call) and
its 1.2x parenthetical did not, for this reason. That container's spec
carries the same table.
