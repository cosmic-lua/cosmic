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
