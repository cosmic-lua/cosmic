# Reviewing: verdicts and the friction feedback loop

review is the planner's first duty in every session (`SKILL.md`), and
it is the system's FINAL GATE: nothing merges without a sophisticated
model judging the implementation against the definition of work AND
the outcome it serves. an item sits in `check` with a PR attached —
that phase means exactly "awaiting a planner verdict", nothing else —
and the planner ends that state with one of three verdicts, every
time. `check` is the only phase a verdict may end, and the verb
refuses one from anywhere else: an accept reaches `land` past every
gate between them, so it may only be given where review happens.

## the review itself

read the item first (`gitboard show ID` — the spec sidecar), then the
PR against it:

1. **acceptance ran.** demand the evidence yourself: the spec's
   `Acceptance` commands, run, ending on the verdict lines they must
   (`ci: PASS`, the narrow checks) — and CI green on the PR's CURRENT
   head. nothing upstream of the review establishes this; the
   implementer owes it and you are the one who checks it was paid. a
   branch that moved since the quoted run (a rework push, a merge of
   main) needs its fresh run read, not assumed; an in-progress run is
   a reason to review the next item and come back, never to wave
   through. absent or failing evidence ends the review immediately —
   verdict 2, "run the acceptance."
2. **the diff is the Change.** everything in `## Change` is present;
   nothing outside it snuck in. scope creep gets cut even when it is
   good — good ideas go to the board as items, not into an unrelated
   diff.
3. **the walls held.** `## Non-goals` items are untouched; frozen
   contracts (the `cosmo.*` C boundary, error strings and return
   shapes, verdict line formats, `definitions.lua` coupling) are
   unmoved unless the spec explicitly moved them.
4. **conventions hold.** AGENTS.md binds: naming, error shapes, file
   caps, cast justifications. anything a gate should have caught but
   did not is itself a finding — for the enablement backlog, not
   just this PR.
5. **it serves the Goal.** walk the item's parent chain to its root
   and judge the change as built against it: does this diff actually
   move that outcome's win condition (or the parent container's),
   or does it satisfy the letter of Acceptance while missing the
   point? this is the judgment only the planner can make — acceptance
   commands prove the spec was implemented; only reading the outcome
   proves the spec was worth implementing as built. a diff that
   passes 1–4 but fails this one means the SPEC was mis-specified:
   fix the specification (and file the ready-bar gap), don't wave the
   diff through.
6. **it is the least thing.** ask of the diff: would a strictly
   smaller one satisfy the same spec? name the surplus concretely —
   a helper with one caller, an abstraction with one instance, an
   option nobody asked for, generality the spec did not demand — and
   request its removal before merge (goals.md's least-thing promise;
   G9 is its measured half, this check is the judged half). the same
   pressure reads the other way: a diff that grew because the SPEC
   over-asked is a ready-bar finding, filed like any other.

## the three verdicts

three verdicts, three directions out of `check`, and one verb records
each: `gitboard verdict ID <kind> --pr N --head SHA` stores the
verdict and the head commit it judged on the item and performs the
move it implies, in one board commit. nothing is posted to the PR to
carry state — write review prose on the PR for the humans reading it,
but the item is the record the tool reads.

- **accept** — `verdict ID accept` moves the item into `land`. the
  move is never refused — a verdict already made is not inventory —
  and the landing itself is implementer-lane work: the finish-first
  rule makes it the first thing the next implementer session picks
  up, squash-merging the PR and running `done ID`. the planner
  judges; the implementer lands. a landing that completes a
  container's last child returns that container to `plan` in the same
  commit, where the next planner pass verifies its stated outcome
  actually holds (run its observable test, not the children's) and
  ends it with `done ID`.
- **request changes** — quote the concrete gaps on the PR, then
  `verdict ID "request changes" --pr N --head SHA` moves the item
  back to `do`, where `next`'s finish-before-pull rule makes the
  rework the first thing an implementer picks up after a landing.
  the same PR carries the fixes; the item returns to `check` with
  them. the item's `verdict_head` records which commit was judged, so
  a reviewer can see at a glance whether anything new followed the
  verdict — read it before re-reviewing, and treat an unmoved head as
  nothing to judge. use this when the work is right-shaped but
  incomplete. never leave a changes-requested item sitting in
  `check`: that phase waits on planners, and implementers do not look
  there.
- **reject** — the approach is wrong, or the item was not actually
  ready. close the PR, record what was learned in the item's spec,
  and `verdict ID reject` sends it all the way back to `plan` (or
  `done ID --reason not-planned` if the work should not happen at
  all). rejection is cheap by design; wrong work merged is expensive.

a research slice (deliverable: recorded findings, no PR) takes the
same three verdicts: accept means re-running the spec's acceptance
checks against the tree — totals recomputed, cited `file:line`s read,
claims spot-verified — then `done ID`, with no move into `land`
because there is nothing to merge. the harvested follow-ups (new
children, corrections to sibling specs) are the SAME session's
refinement obligations, not a note for later: accepted research that
seeds nothing has not finished being reviewed.

## landings invalidate the queue

every landing rewrites main, so any other PR — accepted or still in
review — may now conflict with what landed. a committed ratchet floor
is the classic source of one: two disjoint diffs collide on the derived
lines they both rewrite. `.cosmic-coverage` mostly does not anymore — a
`--baseline` rewrite lowers only the rows the ratchet would have failed
on, and the file merges with git's `union` strategy, so both sides'
rows land and the ratchet reads a repeated path as its lower
percentage. expect this to be rare. when it does happen the recovery is
mechanical and belongs to the implementer lane AT LANDING TIME:
merge main, run the regen command the gate prints, commit, re-run
the gate, land. no fresh verdict is needed when the ONLY conflict is
a regenerated file — the reviewed diff did not change. anything
beyond that (a source-line conflict, a gate that stays red after the
regen) is not a landing anymore: `move ID check` with the conflict
described, and the planner re-judges. the same regenerated-file
conflict appearing on a second PR is enablement evidence under the
feedback half below: file the countermeasure that deletes the
contended line, rather than paying the tax once per landing.

## tuning the limits: the flow review

the WIP limits are committed policy (the `LIMITS` table in
`_work/flow.tl`), and the reviewed change that tunes them starts from
measurement, never from a feeling that a phase is "too tight". the
record is the `board` branch's own git history over `items/*.tl`:
every mutation is exactly one commit, pushed as it happens, so `git
log` over that path is the complete, current record with nothing
separate to fall behind it.

the instrument is `git log --format='%ad %h %s' --date=iso-strict --
items/*.tl`, read by hand — grep and arithmetic over timestamps, not a
report a tool prints. a commit subject's first word is its verb
(`new`, `attach`, `move`, `verdict`, `done`, `block`/`unblock`); a
`move` or `verdict` subject also names the item's 8-character id
prefix and its `<from> -> <to>` phase pair. pairing successive lines
for one id gives that item's stints: a stint starts at a `new`/`attach`
commit that sets phase to `plan`, or at a `move`/`verdict` commit's
target, and ends at the next commit naming that id. from the paired
timestamps, count stints per phase by hand, compute each stint's dwell
(end minus start), and walk the ordered log tracking a running
per-phase set of open ids to get peak concurrent occupancy; the same
walk gives accept/rework/bounce counts and the `ready -> do` pickup
latency (time between the two moves). a `move` subject carrying a
trailing `(forced: ...)` is a repair, not organic flow, and is
excluded.

run a flow review when a limit refuses ordinary intake or an ordinary
pull twice in one session, or after every few dozen landed items.
measure, per phase, over the window:

- **dwell**: median and max minutes per phase stint — sort the
  stints' dwell minutes by hand and read the middle value for the
  median. a phase with a dozen or so stints has too few points for a
  percentile beyond max to mean anything a sorted list does not
  already show by eye; cite the paired `move`/`verdict` lines
  themselves as evidence, not a formula.
- **occupancy vs limit**: the peak concurrent count in each phase,
  and the minutes spent at or over the `LIMITS` value for that phase —
  a phase that never comes near its limit has an irrelevant number,
  not a good one. an item that gains a child is de-phased in the same
  commit as the `attach` that gives it one, so a container never
  carries a phase and never appears as a `move` target; a stint list
  read from `move`/`verdict` lines already counts only workable
  leaves, with nothing to subtract.
- **refusals and their cost**: what motion the limit actually
  refused, and what that cost (lost evidence, stranded work, extra
  planner loops). a refused move never becomes a commit — the verb
  prints its `REFUSED:` line to the terminal and makes no mutation —
  so `git log` has nothing to show for it; this item comes from the
  session's own log, not from the log on disk.
- **backward moves, split by kind**: three log shapes carry backward
  motion, and a hand read must not conflate them. a bounce is a plain
  `move <id> <phase> -> plan` line with no `verdict` prefix — an
  implementer returning work it found under-specified, or a planner
  catching a `ready` item that should not have passed the bar — and
  it sends work back for re-specification. a rework is `verdict <id>
  "request changes" (check -> do)` — a targeted send-back naming
  concrete gaps, the rework signal. `verdict <id> reject (check ->
  plan)` is a third, harsher bounce: the approach itself was wrong.
  none of these is `verdict <id> accept (check -> land)`, which moves
  right, not back — a hand count that greps for `verdict` lines and
  calls anything backward must exclude accept explicitly, or it
  inflates the bounce rate with decisions that were never bounces.
- **pickup latency**: minutes from the move into `ready` to the move
  into `do` — when this far exceeds implementation time, the queue is
  inventory going stale (facts drift, baselines race), not readiness.

then decide by these rules, in order:

1. **check the arrivals before the number.** a full phase still
   admits the motion that cannot wait (`_work/flow.tl` states which),
   and everything else queues. because containers never hold a
   phase, a raw occupancy count read from the log is already a count
   of genuine work in progress: when a hand count shows a phase over
   its `LIMITS` value, check whether the arrivals that pushed it
   there were returns or accepts — which the limit already lets
   through — before treating the number as a real signal that the
   limit itself is wrong.
2. **a limit earns a change only by BINDING**: sustained time at the
   limit plus refusals with real cost. a peak below the limit means
   leave the number alone and record a tripwire instead, in the
   module doc comment at the top of `_work/flow.tl` — the comment
   carries a single line about the limits' origin today, so a
   tripwire is the first line it gains, not an addition to a list
   that already exists.
3. **an oversized queue is cut, not kept.** a phase that never binds
   while its pickup latency dwarfs touch time is aging inventory;
   shrink it until refinement runs closer to just-in-time.
4. **throughput is usually implementer-bound.** the limits' real
   lever is the rework tax — bounces, staleness conflicts, evidence
   loss — so judge a tuning by the wasted-loop rate, not by merges
   per hour.

record the outcome where the numbers live: the module doc comment at
the top of `_work/flow.tl` does not yet carry a review's empirical
basis or any tripwires, so a flow review's findings are the FIRST
evidence appended there, establishing that block rather than
extending one that already exists.

## the feedback half — never skip it

every non-accept verdict, and every bounce an implementer initiated,
carries information about why a presumed-ready item was not. before
ending the session, the planner converts it:

1. name the wrong turn in one line (in the item's spec).
2. pick the countermeasure by the `enable.md` ordering (core > docs >
   skills) and file the enablement item (`gitboard new "title"
   --parent <root> --spec-file F`), or fix the ready-bar gap directly
   if it was this one item's specification failure.
3. if the same wrong turn has now appeared twice, the countermeasure
   stops being optional: file it before refining anything new.

every non-accept verdict carries this in `--enable`, and the verb
refuses one without it: `--enable <item-id>` names the countermeasure
filed, `--enable 'none: <reason>'` records that this item's own spec
was the fault. what the flag cannot judge is whether the reason is a
real one — that part is still the planner's.

a bounce that quotes a wrong or unmeasured tree-fact names its
countermeasure directly — the facts block was missing or stale for
that claim — and the fix is a freshly measured facts entry in the
re-refined spec, not a prose apology.

captured evidence enters the same loop from the implementer side: at
the triage step the planner takes every unplaced root — `attach` it
under the outcome its evidence serves (it enters `plan`), `compare` it
into the order as an outcome of its own, or end it: `done ID
--reason not-planned` for one that will not be worked, `done
ID` for one that landed work already covers, so the record says which
of the two happened. a finding this review itself confirms is
countermeasure evidence like any bounce.

this loop is what makes the system converge: outcomes pull work onto the
board, reviews push friction back into enablement, and over time the
share of items a less sophisticated model completes without a bounce
is the measure that planning is working. a rising bounce rate means
the ready bar drifted or enablement debt is due — spend the next
planner sessions there, not on intake.
