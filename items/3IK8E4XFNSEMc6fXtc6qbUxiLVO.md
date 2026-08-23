Lands in: whilp/cosmopolitan (set the item's repo when it is worked;
no verb sets it at capture time).

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
`literal.parse` (pure Teal: cosmic/_literal_lex.tl + literal.tl) is
~47-53x slower than `json.decode`: 391-404µs vs 7.5µs small,
238-257ms vs 5.2ms on a ~955KB literal (scouting). Lexing is ~80% of
parse: per-char sub(i,i)+match, one {tk,kind,y} table per token (201k
tokens for the large payload). A rewritten jump-scanning Teal lexer
(token-stream-identical, probed) gains 3.0x — best-case pure-Teal
parse ~110ms, still ~20x behind. Pure Teal cannot reach parity.

## Change (hypothesis)
A C data parser `cosmo.DecodeLua` in tool/net beside ljson.c: same
string/number machinery, Lua-literal grammar (quoted/bracket keys,
negatives, long strings, comments), enforcing exactly what
literal.parse enforces — pure data, refuse anything else, nil+err
with line info, depth cap, duplicate-key detection (policy flag or
collect-mode; on_duplicate callers exist: _tool/floor.tl,
_tool/coverage/baseline.tl). Never-execute becomes a property of a
parser with no evaluator — stronger than today. Expected (from
DecodeJson on equivalent data): 238-257ms → ~5-7ms, ~40-50x, parity.
Wrapper keeps the Teal parser as reference implementation;
differential-fuzz C vs Teal (the _fuzz driver already fuzzes the Teal
side).

## Rejected shortcut (recorded so nobody re-tests it)
`load("return "..s, "t", {})`: 2.5-3.5x json.decode — but the
string metatable survives an empty env (("x"):rep(2^30) memory bomb),
expression chunks admit function literals ((function() … end)()), and
bare identifiers silently read nil. Disqualified on the module's own
never-execute promise; keep only as a measured bound.

## Constraints
New frozen C contract: definitions.lua annotations, cosmic type regen
+ wrapper as its own change; fork stays mergeable (surgical diff in
tool/net). Correctness bar: byte-equivalent to literal.parse on the
full fuzz corpus, incl. refusals.

## Risk
Highest effort of the pass; measurement of any C A/B depends on board
item 3IHHJcVr (o//depend broken — header edits never rebuild) landing
first or on clean rebuilds.
