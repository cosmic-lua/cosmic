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
re_gsub_redact_numbers 131µs/38KB (128 matches in 2.5KB),
re_split_colon_list 5.16µs/1.38KB. `all_matches` (cosmic/re.tl:
268-290) materializes a full {Span} list — per match one Span table,
one text:sub copy, one caps table — then gsub (re.tl:408-435) walks
it a second time. For a literal-string repl neither sp.m nor sp.caps
is ever read; split (re.tl:376-393) reads only sp.s/sp.e.

## Change (hypothesis)
Fuse a single find-and-emit loop into gsub/split (keep all_matches
for find_all/gmatch where Spans ARE the product). Probed: a direct
loop over regex:find producing byte-identical output ran 79.9µs vs
129.6µs (−38%); bare finds 53µs = the C floor. Expected: re_gsub
−35-40%, re_split −20-30%, function-repl gsub smaller (it needs
m/caps).

## Constraints
Empty-match rejection via compile_for_iter, NOT_BOL resume semantics
(re.tl:272-277), engine-error propagation (nil, err mid-scan), and
"nil from function repl keeps the match" must all survive; acceptance
shape = output equality with today on the bench corpus + re tests.

## Risk
Low — internal refactor, contract identical.
