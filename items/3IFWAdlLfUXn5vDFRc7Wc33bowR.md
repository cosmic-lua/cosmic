## Evidence

`gitboard help` lists no verb that changes an item's title. `spec`
replaces the sidecar prose; nothing touches the `title` field.

**Three sessions have hit this in four days, each working around it the
same way** — the one the work skill allows once: edit `items/<ksuid>.tl`
and commit directly, bypassing the commit-and-publish path every other
mutation goes through.

- **2026-08-22**, session `sched-n4i2ns` refining `3I9Tko2h`. The item
  was filed as "math.tointeger(tonumber(x)) is unsoundly typed
  non-nilable: 9 untrusted-input parse sites carry no cast and no
  narrowing"; the refinement measured 66 of the 68 sites safe and found
  the real defect in two quicksand proxy parsers. The spec now says so,
  but `next` and `status` print the TITLE, so the board kept asserting a
  claim its own spec retracts. Worked around in `dd776083`.
- **2026-08-25**, refining `3IODJMFv`, filed as "number-to-integer
  narrowing: a `math.type` guard the checker learns from deletes a
  30-cast bucket". The refinement measured the bucket at 13 sites and
  proved by probe that a `math.type` narrowing closes at most one of
  them — so the title named a wrong count AND a mechanism the refined
  spec explicitly rules out. Worked around by hand-editing the
  `["title"]` line.
- **2026-08-25**, refining `3IOK4iuU`, filed as "annotate the cosmo
  bindings that return any, closing 13 from-any sites from
  definitions.lua". The re-measured spec scopes five sites, none in
  `definitions.lua` and none needing a cosmopolitan change at all.
  Worked around in board commit `5246a920`.

That recurrence is the point: the ready bar REQUIRES refinement to
re-measure, and re-measuring routinely invalidates the title the item
was filed under. So this friction is not incidental — it is produced by
the system working as designed, once per refinement that moves a
number.

A title is not decoration: it is what `next`, `status` and `tree`
render, so a refinement that changes what an item IS has no way to say
so, and every read of the board is misled until someone opens the
sidecar. `gitboard retitle ID TITLE`, one commit like every other
mutation.

**Attach under whatever container holds the board machinery's own
defects** — sibling of `3ID0uFdf` (no verb sets an item's repo after it
is opened, so cross-repo work needs a hand edit), which is the same
shape of gap on a different field. No such container exists today; the
backlog carries a dozen of these as unparented leaves.
