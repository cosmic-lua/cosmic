## Evidence

Found by the fresh-context review of cosmic-lua/cosmic#1606 by mutation:
swapping the argument order at the call site `_make/policy.tl:178`
(`wrote_summary(raised_count, lowered_count)` instead of
`(lowered_count, raised_count)`) leaves every test green — the
extracted `wrote_summary(integer, integer)` seam is positional, so the
checker cannot tell the two apart, and `test_wrote_summary_describes_the_breadth_check`
asserts the string from known inputs, not the call site. The same
shape already exists at `_make/policy.tl:167`
(`lines, raised_count, lowered_count = narrate_moves(...)`, from #1576).
`write_baseline` has no end-to-end test on either side of #1606, so a
swap at either seam would print inverted counts — the class of
misdescribing message #1606 exists to fix. Re-locate line numbers at
pull time (`grep -n 'wrote_summary\|narrate_moves' _make/policy.tl`).

## Change

`_make/policy_test.tl`: one end-to-end fixture test for
`write_baseline` — a small committed baseline and a run whose rows
move in both directions (at least one row raised, a different number
lowered, e.g. 1 raised and 2 lowered), capturing what `write_baseline`
prints and asserting the per-row `RAISES`/`LOWERS` lines AND the
closing summary's counts read `2 row(s) lowered, 1 raised`. Choose
unequal counts so a swapped argument at either seam fails the
assertion. Use whatever `_make/policy_test.tl` already has to construct
a baseline and a coverage result in a `TEST_TMPDIR`; if `write_baseline`
cannot be driven without a real coverage run, split the I/O so its
pure core (rows in, lines out) can be, and test that — `wrote_summary`
and `narrate_moves` stay as they are.

## Non-goals

- No change to the message wording landed by #1606.
- No keyword-argument or record refactor of the two seams; the test is
  what closes the gap.
