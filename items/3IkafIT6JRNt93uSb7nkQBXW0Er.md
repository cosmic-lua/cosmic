## Evidence

Observed by the fresh-context review of cosmic-lua/cosmic#1609: after
that PR, `cmd_unhold` refuses a done root and `cmd_done` clears
`is_held`, so the verbs can no longer PRODUCE an item carrying both
`is_held = true` and a `resolution`. But `_work/item.tl`'s `problems`
still does not flag that state — #1609's own test relies on it,
hand-saving a done-and-held item to exercise the refusal. A
hand-edited or pre-existing board file with both fields is refused by
the verbs but accepted by the per-item validator that `store.stage`
runs (`_work/store.tl:253`), so the invariant "a done item never
carries the marker" holds at the verbs and not at the item. Re-locate
with `grep -n 'is_held' _work/item.tl _work/store.tl`.

## Change

Board-tooling change on the `board` branch of cosmic-lua/cosmic, as a
PR against base `board`:

1. `_work/item.tl`, `problems(it)`: report `is_held` on an item whose
   `resolution` is non-empty, beside the existing parented-item guard.
2. `_work/githold_test.tl`: the test that hand-saves a done-and-held
   root to exercise `cmd_unhold`'s refusal must bypass the validator
   deliberately (write the file directly, the way the store test
   fixtures do) or assert the refusal from a state `problems` accepts;
   add one case that `item.problems` reports the done-and-held shape.

## Non-goals

- No change to `cmd_hold`, `cmd_unhold`, or `cmd_done`'s behaviour.
