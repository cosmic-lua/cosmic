## Change

`_work/flowstats.tl` learns the third verdict kind, so a rejected-
then-completed item's rework is counted rather than silently skipped.

Evidence, from PR #1506's fresh-context review (2026-08-29):
`try_verdict` recognizes only `accept` and `request changes`;
`_work/gitverdict.tl` also writes `verdict <id8> reject by <session>`
(its kind == "reject" branch). Measured now: `wc -l <
_work/flowstats.tl` → 370, and `grep -c reject _work/flowstats.tl`
→ 0.

The change, in `_work/flowstats.tl` and `_work/flowstats_test.tl`:

1. `events_of` gains the `reject` arm of the verdict grammar,
   producing a verdict event with its kind.
2. `stats_of` counts a reject as a judged round (rounds += 1) AND as
   rework (numerator += 1, denominator += 1): a reject is a send-away,
   at least as much rework as a request-changes. Decided here, not at
   build time.
3. Tests: the exact subject `verdict abc12345 reject by rev-x` parses
   to a verdict event; an item with take → verdict(reject) → (drop
   clears by the verb, so a fresh take) → verdict(accept) → done
   yields rounds=2 and contributes 1/2 to rework; the existing
   accept/request-changes cases unchanged.

## Non-goals

No change to any verb or verdict-line format; no re-reading of items
files (the log stays the sole input); the summary line's key set is
unchanged — reject only feeds the existing rounds/rework numbers.
