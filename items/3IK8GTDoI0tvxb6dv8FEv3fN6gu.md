Lands in: whilp/cosmopolitan (set the item's repo when it is worked;
no verb sets it at capture time).

Research pass: 2026-08-23, per skills/optimize ("running a research
pass"): four round-1 agents (baseline read, cosmic sweep, C-layer/
startup sweep, literal-vs-json probe) plus a round-2 adversarial
verification. Tree at main 0fb444d6-equivalent. All numbers are
SCOUTING numbers, independently re-measured by the verifier where
stated; accept/reject stays with the _perf harness. C-layer A/Bs
depend on board item 3IHHJcVr (o//depend broken: header edits never
rebuild) landing first, or on clean rebuilds.

## Problem
json_decode_large 929µs (baseline). tool/net/ljson.c case '\''"'\''
(line 323, loop 327-341) pushes ONE BYTE at a time via luaL_addchar
through a 256-entry class table even for plain ASCII runs — verified
verbatim, and no span/memchr fast path exists anywhere in the string
case (323-584). Prior perf work landed elsewhere (table presizing
lua_createtable(L,8,0)/(L,0,8) at 253/295; arraymt registry lookup
hoisted, 640-644) and did NOT touch this loop.

## Change (hypothesis)
Scan ahead to the next quote / backslash / control byte / ANY BYTE
>= 0x80, and lua_pushlstring (or luaL_addlstring) the clean span
directly. The >=0x80 boundary is REQUIRED for correctness, not
optional: multi-byte input is decoded and re-encoded (goto
EncodeUtf8; CESU-8 surrogate pairs merge into different output bytes,
UTF8_3_ED at 493-520; overlong/invalid UTF-8 rejected at 557/564/
572), so only 0x20-0x7F minus quote/backslash is byte-identical
pass-through. \u escapes unaffected (they start with backslash).

## Expected win (verifier-corrected)
~5-10% on json_decode_large, NOT the 15-30% first estimated: the
payload'\''s ~43KB of string bytes cost ~2.3ns/byte in the loop
(~0.10ms, ~11% of decode), and a span path removes at most 70-80% of
that; per-string fixed costs (interning in luaL_pushresult, table
inserts) dominate the short strings and are untouched. Bigger wins
only on long-string-heavy payloads.

## Constraints
Byte-identical output incl. all \u and invalid-UTF-8 error behavior;
definitions.lua untouched (no contract change); differential-fuzz
old vs new decoder.

## Risk
Low — localized. Ambition medium; worth doing as a clean, easily
verified slice, with honest expectations.
