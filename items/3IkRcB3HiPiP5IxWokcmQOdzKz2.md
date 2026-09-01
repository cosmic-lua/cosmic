## Evidence

Found by the fresh-context review of cosmic-lua/cosmic#1607 (the
`is_held` marker), by reading the refusals side by side at head
`858ad603`:

- `_work/gitcompare.tl:146` — `cmd_unhold` checks only `is_held`, so on
  a root that was held and later ended with `done` it returns 0 and
  clears `is_held` on a done item, while `cmd_hold` refuses a done root
  and `cmd_set` refuses any done item ("a done item's facts are history,
  not a repair target").
- `done` itself leaves `is_held` standing on the item it ends, so a
  held-then-done root carries both `is_held = true` and a resolution.
- `_work/item.tl:232`'s `problems` guard (`is_held` on a parented item
  is refused) has no test: disabling it leaves the whole `_work/` suite
  green (34/34); only a hand probe of `cmd_attach` showed the refusal.

Re-locate at pull time with `grep -n 'is_held' _work/*.tl`.

## Change

Board-tooling change on the `board` branch of cosmic-lua/cosmic, landed
as a PR against base `board` (same as #1607):

1. `_work/gitcompare.tl`, `cmd_unhold`: refuse a root that is not open
   with the same wording shape `cmd_hold` uses for a finished root.
2. `_work/gitverbs.tl`'s `done` path (or wherever `resolution` is set
   on the item; `gitverbs.tl` is at the 500-line cap, so put the clear
   in the helper that already builds the ended item, not a new branch
   in the verb): clear `is_held` when ending an item, so a done item
   never carries the marker.
3. `_work/githold_test.tl`: two cases — `cmd_unhold` refuses a done
   root; ending a held root leaves `is_held` unset. And one case that
   `item.problems` reports `is_held` on a parented item, so the guard
   at `_work/item.tl:232` is no longer mutation-invisible.

## Non-goals

- No rendering of `is_held` in `show`/`status`.
- No change to `hold`'s own refusals.
