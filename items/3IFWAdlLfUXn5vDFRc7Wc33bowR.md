## Evidence

`gitboard help` lists no verb that changes an item's title. `spec`
replaces the sidecar prose; nothing touches the `title` field.

Hit on 2026-08-22 by session `sched-n4i2ns` refining `3I9Tko2h`. The
item was filed as "math.tointeger(tonumber(x)) is unsoundly typed
non-nilable: 9 untrusted-input parse sites carry no cast and no
narrowing"; the refinement measured 66 of the 68 sites safe and found
the real defect in two quicksand proxy parsers. The spec now says so,
but `next` and `status` print the TITLE, so the board kept asserting a
claim its own spec retracts.

The workaround used was the one the work skill allows once — edit
`items/<ksuid>.tl` and commit (`dd776083`) — which bypasses the
commit-and-publish path every other mutation goes through.

A title is not decoration: it is what `next`, `status` and `tree`
render, so a refinement that changes what an item IS has no way to say
so. `gitboard retitle ID TITLE`, one commit like every other mutation.

**Attach under whatever container holds the board machinery's own
defects** — sibling of `3ID0uFdf` (no verb sets an item's repo after it
is opened, so cross-repo work needs a hand edit), which is the same
shape of gap on a different field.
