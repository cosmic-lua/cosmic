## Change

No code. Confirm that both halves of the Lua 5.5 bump have merged to
their respective `master` branches:

- `cosmic-lua/cosmopolitan#294` — the vendored-interpreter bump
  (5.4.9 → 5.5.1) and its const-control-variable fix.
- `cosmic-lua/cosmic#1587` — the carried tl patch that shadows a
  reassigned `for` control variable in generated Lua, needed for
  `require("cosmic.string")` to keep loading once cosmic itself runs
  on 5.5.

Both are currently draft, opened 2026-08-31 by the repos' human
maintainer, with the PR body stating explicitly "Neither PR is
useful alone, so both are draft until they land together." — this
item exists so the pin-bump item (blocked on it) is not re-offered
until that has actually happened.

`gitboard done` this item once both PRs show `merged: true` (quote
each PR's merge commit); if either is closed unmerged or superseded,
record that instead and re-open the question of what the pin-bump
item should block on next.

## Non-goals

- Merging either PR. Both belong to a human contributor; nothing
  here reviews, approves, or merges them.
- Any part of the pin-bump work itself (cutting the cosmos release,
  bumping `3p/cosmos/cosmos_pin.tl`, running `bin/cosmic --make ci`)
  — that is `Muzf_hbQP`, unblocked by this item's `done`.
