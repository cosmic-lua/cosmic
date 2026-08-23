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
format_module_source 6.83ms cw1.00 with 1478KB allocated per op —
and this cost is paid per file by every --make fmt/ci across the
tree, so it is toolchain wall clock. Links (imports, never
duplicates) open issue whilp/cosmic#1102 ("the formatter allocates
~100x its input"), adding this decomposition: tl.lex 2.02ms +
tl.parse_program 1.58ms ⇒ 3.23ms (47%) is cosmic-owned emit code in
cosmic/format/init.tl.

## Change (hypothesis)
In increasing ambition: (a) stop copying every one of ~4000 tokens
into fresh Item tables in build_items (format/init.tl:94-120 — ~1/3
of the alloc) by annotating lex tokens in place (they are locally
owned after tl.lex; prove nothing reads them after); (b) buffer
per-line and concat once per line instead of thousands of tiny out[]
fragments; (c) fold mark_type_params' per-line re-scan into the
single emit walk. Expected 20-30% of the scenario (bounded by the
47% emit share). The other 53% is tl.lex+parse where parse exists
only to gate syntax errors — 3p/toolchain territory (e.g. one
lex/parse shared between fmt and check), out of scope here.

## Constraints
The fmt gate is the acceptance test: byte-identical output over the
whole tree; idempotence pinned by the scenario check; fixpoint gate
means the formatter change must pass under its own formatting.

## Risk
Medium — emit rules are fiddly; token-table mutation must be proven
safe.
