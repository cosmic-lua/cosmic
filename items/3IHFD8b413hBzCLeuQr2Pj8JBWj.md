## Goal

G6 — the defining paths answer for a release. tar_extract_tree is the
one genuine regression inside the release gate's five red days
(3IHCIZWU's A/B separated it from 17 runner-variance flags), and it
implicates how the pinned cosmos builds, not what cosmic wrote.

## Evidence

Interleaved A/B, 2026-08-22, one machine: A = 2026-08-17-f421fa1
release binary (cosmos 2026.08.15, default-mode lua), B = main at
ff09b575 (cosmos 2026.08.21, MODE=rel lua). tar_extract_tree, 5
alternating pairings:

    A: 7.62 7.55 7.29 7.44 7.32 ms   (tight)
    B: 10.04 7.84 7.91 10.17 8.09 ms (slower in every pairing)

~+8% at the floor, spikes to +37%; the CI compare saw +69% same
direction. 42 of 43 other scenarios are within noise, so this is not
machine drift. `git log --since=2026-08-17 -- cosmic/tar*` is empty:
no cosmic-layer change. The moving parts are the two cosmos pin bumps
(be9b1faf, aaf4af95), and the 2026-08-21 cosmos releases are the
first cosmic has pinned that ship lua as MODE=rel
(whilp/cosmopolitan#261).

That is whilp/cosmopolitan#262's documented failure mode: MODE=rel
drops the ftrace padding, code layout shifts per link, and on
Skylake-family CPUs a hot loop whose branch straddles a 32-byte
boundary eats the JCC-erratum penalty — a per-link lottery, observed
there as codec_hex +34-38% in one rel link. The padding fix
(-Wa,-mbranches-within-32B-boundaries, PR'd 2026-08-15 on branch
claude/1107-cosmic-yd5vj4) was never merged.

## Direction

Decide in whilp/cosmopolitan: land the 32-byte branch-padding flag
for x86_64 rel (the #262 fix), cut a release, bump the pin, and
re-run the A/B above — if tar_extract returns to A's numbers, done;
if not, bisect the two pins with perf record on lua.dbg per
skills/optimize/cosmopolitan.md. Either way the repro is two
commands and five minutes.
