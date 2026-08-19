# Decomposing: from ambiguous goals to workable items

working backwards is the core move: start from an outcome's
win condition, find the largest gap between it and today, and keep
cutting until each piece clears the ready bar. refinement is
incremental — an outcome does not decompose in one sitting, and is not
supposed to; a refine action takes the first `plan` item ONE rung
down.

## the refinement ladder

three rungs, each with an exit test. an item names its rung by its
position in the graph; moving down a rung is what "refine" means.

1. **outcome** — a placed root on the board; its prose, its
   measurement, and its win condition live in
   [docs/goals.md](../../docs/goals.md). ambitious and ambiguous by
   design ("no silent bugs", "best tool-building tool"). an outcome
   changes by PR to goals.md, and its standing against the others by
   `gitboard compare`, never by ordinary refinement.
2. **container** — an item under an outcome with open children: one
   result in service of it, still too big or too undecided to hand
   over. an item BECOMES a container by decomposition — attach a
   child under it (`gitboard new "child" --parent <id>`, or
   `attach`) and the tool de-phases it in the same mutation.
   *exit test:* the outcome is observable ("a fresh clone can X", "the
   eval suite scores Y") and its child leaves exist under it.
3. **slice** — a workable leaf: one session, one PR.
   born in `plan`, moved to `ready` once it clears the bar.
   *exit test:* the ready bar below, checked by `gitboard check ID`
   and a considered read of its content.

decomposition mechanics: children point at their parent (the
`--parent` edge), so there is no checklist to maintain and none to go
stale — `tree` renders the decomposition from the edges. a slice that
needs another slice first records it with `gitboard block ID BLOCKER`
(`next` skips items with open blockers, and the verb refuses an edge
that would deadlock the pair). when every child is done, the
session verifies the container's outcome actually holds and ends it
(`review.md`).

## ordering the work: paired comparison

intake walks the placed roots top-down (`next` names
the highest-placed one with no live work), so the order has to be
real — and it is not asserted anywhere. it is DERIVED from committed
comparisons, so deriving it is the same act as recording one: put a
contested pair to the goal owner, ONE question at a time —

> if cosmic could hold only one of these win conditions over the next
> several releases, which is the better cosmic?

— and commit the answer with `gitboard compare <winner> <loser>`.
transitivity closes the untested pairs for you (A > B and B > C
settles A vs C, with nobody asked), so a handful of questions orders a
half-dozen outcomes. give byes to outcomes that are nearly holding
(finish, don't debate) or dormant.

the same verb orders anything, at any height: two containers fighting
for capacity, two slices under one parent, a capture against the
outcome it might displace. a comparison at any height places
everything beneath it, so ordering two outcomes orders their subtrees,
and comparing two leaves refines the order inside a band without
disturbing the bands.

an intransitive cycle (A > B > C > A) is never averaged away —
`status` reports it and the tool refuses the edge that would close
one, because a cycle means the comparison question was ambiguous.
restate what "better" means, `uncompare` the edge that no longer
holds, and re-ask just that pair. AHP (Saaty) is the heavyweight
variant with weighted judgments and a consistency ratio; the plain
tournament converges faster and its record is the commit log.

each answer is committed as it is given: `compare` is one commit on
the board, which is what intake reads, and a PR to goals.md reorders
the outcome prose and records the matches in its description
([D25](../../docs/decisions/d25-outcomes-and-instruments.md)). a
ranking that lives in a conversation is not a ranking — which is the
whole reason the comparisons are the stored thing and the order is
not.

## sizing a slice

a ready slice is sized for one session: one PR, a diff a session can
hold in its head (~400 lines touched is the smell
threshold, not a rule), zero decisions left open. if writing the
`Change` section forces the word "and" between two independent
changes, cut it in two. if a slice cannot be sized without research,
the research IS the slice: an enablement item whose deliverable is
recorded evidence and the follow-up slices, not code.

slices are also sized for each other: sessions run in
parallel, so prefer cutting an outcome into file-disjoint slices (two
ready slices touching the same files invite merge conflicts and
serialized rework). a `blocked_by` chain is the tool for real landing
order — one enablement slice unblocking many parallel siblings is a
good shape; a chain of siblings each blocking the next is a slice cut
wrong.

the clauses to write into a slice whenever they apply. a slice whose
diff moves, adds, or removes gated material (casts, coverage, any
committed baseline) should say what to do when a ratchet gate
complains: run exactly the regen command the gate's failure message
prints and commit the result — in scope, never a gate weakened any
other way. a slice near a frozen contract names the contract in
`Non-goals` (see anti-patterns). a slice whose spec imposes a numeric
bound (a per-file cap, a count ceiling, a size budget) writes it into
`Acceptance` as a command with its bound, never as `Change` prose (see
the ready bar below). and a slice whose `Acceptance` commands take
path arguments or write files keeps them literal-runnable: safe and
meaningful to run verbatim from the repo root, touching no committed
file, and naming only argument shapes a test already covers.

## the ready bar

a ready slice's spec sidecar carries exactly these five sections.
`gitboard check ID` lints that each is present and non-empty, and
that the item has a position in the priority order (`move ID ready`
refuses a slice that fails the same lint); only a reader can judge
their content. the test for every sentence: **could a competent but
literal-minded session, with no context beyond this spec and the
repo's AGENTS.md, get this wrong?** if yes, it is not ready.

- `## Goal` — one line naming the outcome (or container result) this
  serves, for the reader. prose, judged by a person: the tool
  checks that the item has a POSITION in the priority order, not what
  this line says.
- `## Change` — what to build, naming the files to touch and the
  shape of the change in each. imperative and concrete: "add verb X
  to `_cli/build/`, dispatching to ...", never "improve", "clean up",
  "investigate", or "support".
- `## Non-goals` — the walls: contracts that must not move, files not
  to touch, adjacent improvements not to make. this section is what
  keeps a diligent session from helpfully breaking something.
- `## Acceptance` — the exact commands to run and the verdict lines
  they must end with. `bin/cosmic --make ci` ending `ci: PASS` is the
  floor; add the narrow checks that prove THIS change (a specific
  test file, a fixture build, a `--docs` lookup showing the new
  entry). anything not checkable by a command is not acceptance —
  rewrite it until it is. a numeric bound the spec IMPOSES (a
  per-file line cap, a count ceiling, a size budget) is written as an
  Acceptance command with its bound (`wc -l <file>` ≤ N, `grep -c` =
  N), never as `Change` prose; `Change` may motivate the number, but
  the Acceptance command is the contract, and a bound with no command
  is the "acceptance by vibes" anti-pattern wearing digits. an
  Acceptance command must be safe and meaningful to run literally,
  verbatim, from the repo root: it may not write into the committed tree,
  and the argument shapes it names must be shapes a test actually
  covers.
- `## Enablement` — the record of the enablement check
  (`enable.md`): either `none needed` with a word on why, or the
  blocker items (by id) that must land first, mirrored in
  `blocked_by`.

**measured, not inferred.** every tree-fact the spec relies on (a
file's length or headroom, a pattern's match count, a function's
location) is measured DURING the refinement pass that asserts it, and
written into the prose with the command that produced it. a `Change`
that grows a named file states that file's measured headroom — the
500-line ceiling makes placement a capacity question. a `Change` that
narrows a function's contract enumerates that function's callers
(`grep -rn` the call sites), so no caller is discovered broken at
implementation time. an `Acceptance` that greps for a count states
what the same pattern returns TODAY, and a widened or reworded
pattern is re-measured rather than carried over.

naming the command beside its output is what makes the claim
checkable, by a reviewer or by whoever holds the spec next.
nothing runs these on the item's behalf and nothing pretends to: a
measurement that has gone stale is caught by whoever runs it next,
which is the reason to write every one of them to be runnable.

## a worked example

the spec sidecar of a ready slice:

````markdown
## Goal
G4 — zero-config project gates (this item's parent is the G4 root)

## Change
Teach `--make ci` to print per-stage durations. In
`_make/verbs.tl`, wrap each stage call with `cosmic.instrument`
spans named `stage=<name>`; print one `<stage>: <secs>s` line as
each stage ends, before the existing verdict line. measured now:
`wc -l < _make/verbs.tl` is 340 (160 lines of headroom under the
500-line cap) and `grep -c "cosmic.instrument" _make/verbs.tl` is 0.

## Non-goals
No new flags. No change to the `ci: PASS`/`ci: FAIL` verdict line
format — downstream scripts parse it. No timing inside stages.

## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS` and prints one duration
  line per stage.
- `bin/cosmic --make test _make/verbs_test.tl` passes, including
  the new `test_stage_duration_lines`.

## Enablement
none needed — `cosmic.instrument` already covers this; conventions
are in AGENTS.md.
````

## anti-patterns

- **research verbs in Change** ("investigate", "explore", "figure
  out") — that is a `plan` item or an enablement research slice,
  not ready work.
- **acceptance by vibes** ("works correctly", "is faster") — commands
  and verdict lines, or it does not go in Acceptance. for performance
  work, the `optimize` skill's gates are the acceptance. a numeric
  bound left in `Change` prose is the same anti-pattern wearing
  digits: PR #1264 shipped two files 14–73% over its spec's 200-line
  cap, unnoticed through four green CI runs, because the cap was
  never an Acceptance command.
- **hidden decisions** ("pick a reasonable format") — refinement
  picks; the spec states the pick.
- **scope by omission** — an empty Non-goals section on a change near
  a frozen contract (the `cosmo.*` C boundary, error strings, verdict
  line formats) is a refinement error; name the walls.
- **decomposing to dust** — slices so small the overhead dominates
  (rename-only items, one-liner items in a chain). a slice earns
  its place by being independently verifiable, not by being tiny.
