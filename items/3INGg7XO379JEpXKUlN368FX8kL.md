## Goal

A long bracket read by either literal reader equals what `load`
returns: `\r\n`, `\n\r` and `\r` normalize to `\n` while copying the
body, and one such sequence right after the opening delimiter is
dropped (Lua's read_long_string/inclinenumber rule). Today both
readers keep the CR bytes — the measured table in the capture shows
five DIFFER rows — so a CRLF checkout feeds a build patch text Lua
would not produce, silently.

## Change

One change in two places, C FIRST — this is an ACCEPTANCE divergence,
so cosmic's C-refusal fall-through does not cover it: landing the
Teal half first would make engine="auto" (the C reader, old pin)
return different bytes than engine="teal" on the same source.

1. whilp/cosmopolitan (`tool/net/llua.c`, ScanLongString): normalize
   the four line-ending forms to `\n` while copying; drop ONE
   normalized sequence after the opener instead of a bare `\n`.
   `test_llua.lua`: the byte sweep over long brackets stops excluding
   byte 13 (the acceptance signal named in the capture) and the CR
   table's five cases assert equality with `load`. Rides the
   designated branch AFTER whilp/cosmopolitan#283 merges (the branch
   holds one PR at a time).
2. whilp/cosmic (`cosmic/literal.tl`, string_value's long-bracket
   branch): same normalization; engine corpus gains a CR case. Lands
   only once the cosmos pin carries (1) — before that the two engines
   would disagree on the new corpus case.

## Non-goals

Short strings (raw CR inside one is Lua-refused territory, unchanged
here); long comments (already agree — CR there is skipped either
way); no refusal changes.

## Acceptance

Upstream: `make o//tool/lua/test` PASS with the byte-13 exclusion
gone and the five load-equality cases. Cosmic (stage 2): `--make ci`
PASS; the engine corpus CR case agrees byte for byte; the five
capture rows read `agree`.

## Enablement

Stage 1 waits on whilp/cosmopolitan#283 (branch contention only).
Stage 2 waits on the first cosmos pin bump carrying stage 1 — the
same wall as 3INAsVJZ's C half, currently behind the perf-gate fix
(3ITt7slj).

## Result (stage 1, 2026-08-27)

Stage 1 is DONE as whilp/cosmopolitan#284 (branch contention with
#283 resolved by using a different designated branch): ScanLongString
normalizes the four line-ending forms while copying and drops one
full sequence after the opener; test_llua.lua retires the byte-13
exclusion (the named acceptance signal) and adds five load-equality
cases. `make o//tool/lua/test` PASS on the PR head.

Stage 2 (cosmic/literal.tl string_value + engine corpus CR case)
remains, behind this PULL-TIME GATE: the cosmos pin
(3p/cosmos/cosmos_pin.tl) must name a release whose base carries
whilp/cosmopolitan#284's merge — before that, engine="auto" (C
reader) and engine="teal" would disagree on the new corpus case.
If the gate fails at pull, bounce back rather than building; do not
merge #284 yourself — upstream merges are the owner's.
