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
fuzzy_find_similar 608µs/52KB. cosmic/fuzzy.tl:25-28 allocates two
fresh DP row tables per distance() call (258 tables per op here) and
always runs the full O(n·m) DP even when every cell already exceeds
the caller's max_distance (fuzzy.tl:31-47).

## Change (hypothesis)
Internal bounded-distance helper for find_similar: module-shared
prev/curr rows (reset by index range) + abort when the row minimum
exceeds max_distance. Probed: 579.5µs → 354.5µs (−39%), identical
result set. Optional second step: Ukkonen band (cells within
max_distance of the diagonal) → O(k·n), win grows with candidate
length (real "did you mean" sets of long module names). Public
distance() contract untouched.

## Constraints
Exact same match set, distances, sort order, dedup-on-lowercase;
shared rows are single-threaded-VM safe but must not persist garbage
between calls and the helper must not yield.

## Risk
Low.
