Research pass: 2026-08-23, per skills/optimize ("running a research
pass"), driven by four round-1 agents (full-suite baseline read, cosmic
sweep, C-layer/startup sweep, literal-vs-json probe) plus a round-2
verification pass. Tree at main 0fb444d6-equivalent; binary o/bin/cosmic
built from it; full-suite baseline in that session (json_decode_large
929µs, fs_walk_tree 354.7µs/73KB, format_module_source 6.83ms/1478KB,
startup_run_lua 2.35ms cw0.07, embed_extract_tree 59.9ms cw1.01). All
probe numbers below are SCOUTING numbers (os.clock/shell loops, medians
of 3+), not the _perf gate; accept/reject stays with the harness.

## Problem
`literal.format` (pure Teal, cosmic/_literal_format.tl) runs ~8-9x
slower than `json.encode`: 88µs vs 11.5µs on a ~1.2KB map payload,
60-71ms vs 6.4ms on ~640KB (scouting). Decomposition: walk+sort 15%,
%q quoting 22%, ~63% per-entry string assembly and double walk.

## Change (hypothesis)
This fork still carries redbean's C serializer `cosmo.EncodeLua`
(tool/lua/lcosmo.c:230, sharing ljson's LuaEncodeSmth machinery), at
1.2-1.3x json.encode, and its sorted MAP output already round-trips
through `literal.parse` byte-perfectly (verified incl. \xff,
newline keys, negatives; positional-array output is refused). But it
never refuses: NaN→0/0, inf→math.huge, cycles→"cyclic@0x…",
functions→"func@0x…" — silent corruption by literal's standards. Two
variants:
(a) cosmic-layer fast path: strict Teal pre-walk (refuse NaN/inf/
functions/cycles/non-string keys; ~10.5ms on the large payload, can
skip sorting) then EncodeLua → ~9-19ms, near parity;
(b) C `strict` option on EncodeLua that refuses instead of
stringifying → ~9ms, parity; contract addition needing
definitions.lua + type regen as its own change.

## Constraints
EncodeLua's layout is NOT literal.format's fmt-fixpoint pin layout —
keep `format` for writing pins (rare, small); this is the bulk
codec path, or extend the C with layout options. literal's founding
promise (module header): values only, refuse everything else.

## Risk
Low for (a); (b) touches a frozen C contract (separate deliberate
change per the fork's rules). Sibling capture: the decode half
(cosmo.DecodeLua) — the two together are "literal at json speed".
