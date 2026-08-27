## Goal

The cosmos pin (`3p/cosmos/cosmos_pin.tl`) names a release whose base
carries whilp/cosmopolitan#284's merge (ScanLongString CR
normalization — 3INGg7XO's stage 1). Merging #284 is the owner's call,
then the next push-to-master release carries it, then a cosmic cosmos
pin bump lands it here.

## Result

Done when a merged cosmic cosmos pin bump names a release whose tag
commit has #284's merge as an ancestor. End this item then; it exists
so 3INGg7XO (stage 2, the Teal reader's matching change) carries a
real blocker edge instead of being re-offered by next while the C
half is unreleased — the two engines would disagree on the new corpus
case until then.

The edge STILL BINDS, re-checked 2026-08-27T04:0xZ. 3INAsVJZ's C half
was order-free because a C REFUSAL falls through to the Teal lexer
(`cosmic/literal.tl:378-382`), so both engines returned the fixed
value under any pin. #284 is not that shape: both readers accept the
same source and would return DIFFERENT BYTES, which no fall-through
covers. So this edge is not one to drop — stage 2 genuinely waits.

Stage 1 is finished and verified, independently of its author. On
#284's head `bbd9278c` (base `3977e62f`), in a fresh checkout of this
container:

- `make -j4 o//tool/lua/test` → `PASS`, exit 0.
- The acceptance signal 3INGg7XO named is really retired:
  `test_every_byte_in_a_long_bracket` no longer excludes byte 13
  (`git diff 3977e62f -- tool/lua/test_llua.lua`), and the new
  `test_long_bracket_line_endings_match_load` asserts load-equality
  over all five forms (`\r\n`, `\r`, `\n\r`, a dropped leading
  sequence, and a mixed run), wired into the runner list.
- The C copy matches Lua's own rule read against llex.c: the
  pre-loop block mirrors `inclinenumber` (skip one newline byte, then
  a second only if it is a newline of the OTHER kind), and the body
  loop folds each of the four forms to one `\n` — so `[[\n\nx]]`
  still yields `"\nx"` and `[[\r\r]]` yields `"\n"`.

So nothing technical remains on stage 1; what remains is the merge
decision, the release it rides, and the pin bump. One fact worth
carrying into that pin bump: cosmic's engine corpus
(`cosmic/literal_engine_test.tl`'s NESTED) has no CR in its long
bracket — the tree is LF-only — so the bump does not by itself break
engine agreement; only stage 2's new corpus case needs the two
readers moved together.
