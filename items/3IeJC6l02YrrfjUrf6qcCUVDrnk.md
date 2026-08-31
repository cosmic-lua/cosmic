## Evidence

Board item 3I1Rvbva (coverage --baseline: refuse a bad rewrite instead
of clamping a good one, cosmic-lua/cosmic#1576, merged) went through
five review rounds and, along the way, fixed most of what this item
originally flagged: `_make/policy.tl`'s per-row narration now correctly
labels a raise `RAISES` and a drop `LOWERS` (via `narrate_moves`), and
`cosmic/coverage/SENSITIVITY.md` was rewritten to accurately describe
the honest two-directional rewrite and the `corpus_guard` breadth
check, dropping the false "every other row survives byte for byte"
reassurance.

One line was missed. `_make/policy.tl:160` (`write_baseline`'s closing
summary, printed after every successful `--baseline` write):

```text
io.write("coverage: wrote " .. BASELINE .. " (" .. lowered_count
  .. " row(s) lowered, " .. raised_count .. " raised; a floor only"
  .. " moves up by hand — see cosmic/coverage/SENSITIVITY.md)\n")
```

`"a floor only moves up by hand"` is now false: #1576's entire point is
that a floor raises automatically on a trustworthy `--baseline` regen,
narrated right above this same line (`raised_count` in this very
message proves it). The parenthetical is a leftover from the pre-#1576
one-way clamp and contradicts the `raised` count in the same sentence.

## Change

`_make/policy.tl:158-161`: rewrite the closing summary's parenthetical
to describe the current mechanism instead of the deleted clamp — e.g.
name the `corpus_guard` breadth check as what actually gates a
rewrite, and point to `cosmic/coverage/SENSITIVITY.md` for why an
environment-sensitive row still needs a human look, rather than
claiming raises need manual intervention (they don't; the message's
own `raised_count` already reports them happening automatically).
Re-verify exact wording against the current file at pull time — quote
the surrounding lines, since the message is one `..`-chain and easy to
mis-slice.

Check the message's own test coverage while there: `_make/policy_test.tl`
gained `test_narrate_moves_labels_each_direction` in #1576, which
covers `narrate_moves` but not necessarily this closing-line string
verbatim — extend it (or add a case) if the string isn't already
asserted somewhere.
