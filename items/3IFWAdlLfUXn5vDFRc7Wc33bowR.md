## Change

One `set` verb repairs the three destination-fact fields an item can
carry but no verb can change after open: `title`, `repo`, and a NEW
`base` (the branch the item's PR targets). This consolidates three
captures of the same gap shape: retitle (three sessions hand-edited
item files in four days — evidence retained below), repo-after-open
(3ID0uFdf: a cross-repo destination learned late has no verb, HTTP
404s at handover), and base-branch (3ISQBIua: non-main targets live
only in prose and nothing catches a PR opened against the wrong
base). Both siblings are blocked on this item and verified against
it when it lands.

Measured 2026-08-29: gitverbs.tl is 494/500 — no room — so the verb
lives in `_work/gitgraph.tl` (234 lines, home of new/attach/block)
or its own `_work/gitset.tl` if graph would pass ~460. item.tl:127
declares `repo: string | nil` with a shape check at :200; there is
no base field. gitgate.handover_refusal is at gitgate.tl:178
(291-line file). Dispatch is a flat if-chain in gitboard.tl.

1. `gitboard set ID --title T | --repo OWNER/NAME | --base BRANCH`
   (at least one flag; multiple compose). Walls, enforced by the
   verb: ONLY these three fields — claim, pr, verdict, resolution,
   parent, blocked_by, lane have their own verbs and gates, and
   `set` refuses them by not existing for them. Repo keeps its
   :200 shape check; base takes a plain branch-name shape
   (`^[%w%-%._/]+$`). Setting on a done item refuses (history).
   The mutation commits as `set <id8> <field>[ <field>...]` — the
   VALUES stay out of the subject (titles are long); the diff
   carries them.
2. `_work/item.tl`: add optional `base: string | nil` beside repo,
   with encode/decode and the shape check.
3. The base gate: `gitgate.handover_refusal` additionally refuses
   when the item carries a non-empty `base` and the PR's base ref
   (gh.pull already returns the PR — measure which field carries
   the base ref and extend gh.pull if it does not) disagrees:
   `REFUSED: PR #N targets <actual>, the item says <base> — retarget
   the PR or set --base`. An item with NO base field is ungated
   (today's behavior, and board-machinery items whose PRs target
   `board` stay valid without backfill).
4. `show ID` renders repo and base on their existing field lines
   (measure how repo renders today and match).
5. Tests in the verb file's own `_test.tl`: set title/repo/base
   round-trip through a real store; refusal on a done item; refusal
   on an unknown flag; the base-gate refusal (PR base mismatch) and
   pass (match, and absent-base ungated) — mutation-verify the gate
   test goes red when the gate comparison is removed.

## Non-goals

No flow-state fields ever. No backfill of base onto existing items.
No skill/README prose changes here (the skill's branch-cutting prose
is 3ISQBIua's residue — reconciled when that item is verified against
this landing). Verdict lines, refusal grammars elsewhere, commit
subjects other than the one NEW `set ...` grammar untouched
(_work/flowstats_test.tl proves).

---

(Original retitle evidence:)

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
