## Goal

Every end-of-input refusal in `cosmic.literal`'s reader is reachable,
and the internal `$EOF$` spelling never leaks into a message. Today
two refusal messages are dead (the lexer's sentinel gets there first)
and truncated input reports `found '$EOF$'` instead.

## Change

Decision (from the capture's two options): make the messages
reachable at the sentinel — the better-reading choice — rather than
deleting them. Cosmic-only: the C path discards its own refusal,
message and offset both, and re-reads with the Teal lexer
(cosmic/literal.tl parse()), so refusal messages are Teal-only
surface and the refusal INPUT set does not move.

In `parse_table` (cosmic/literal.tl):
- loop head: a sentinel token refuses `unterminated table in <noun>`
  with its line — reachable by `return {` and, via the separator
  change below, `return {a = 1`;
- value position: the dead `if not v` guard becomes a sentinel check
  refusing `unexpected end of <noun>` with its line — reachable by
  `return {a =`;
- separator position: a sentinel is left for the loop head instead of
  being reported as `found '$EOF$' after a value`; the `not sep` arm
  and the `"<eof>"` fallback go (the sentinel means sep is never
  nil);
- the loop's dead fall-through `unterminated table` return goes with
  the restructure, so coverage stops carrying unreachable lines.

Tests asserting the old `$EOF$` spellings update to the new
messages; `literal_engine_test.tl`'s byte-for-byte engine agreement
holds by construction (both engines report the Teal message).

## Non-goals

No refusal-set change (both readers refuse the same inputs before and
after); no C-side change; no new refusal classes. The C parser spec's
class count (3IKSjEgW) is that item's record, not this one's.

## Acceptance

`--make ci` ends `ci: PASS`. `literal.parse` on `return {`,
`return {a =`, `return {a = 1` reports the end-of-input messages with
no `$EOF$` anywhere; `grep -c '\$EOF\$' o/cosmic/literal.lua` shows
the spelling only where the sentinel is consumed, never concatenated
into a message. Coverage carries no unreachable refusal line in
parse_table.

## Enablement

None.
