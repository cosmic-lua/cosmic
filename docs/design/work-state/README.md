# work state in a git repository

A design exploration, with a working spike: move the work system — its
coordination state AND its hierarchy — out of GitHub labels and
comments and into files committed in a git repository. Long-lived
ranked goals, the epics that decompose them, the slices an implementer
pulls, and the findings awaiting triage are all first-class items in
that repository. Pull requests stay on GitHub and keep doing what they
are good at: a PR holds a diff, its CI, and its review conversation.
Issues shrink to an inbound queue — a bug report or an external
request arrives there and is imported as a finding — instead of being
the board's storage. Nothing accumulates claim comments, PR-link
comments, or `work-verdict:` comments, because no state lives where
those comments used to put it.

The spike is `_work/item.tl` (the item codec), `_work/flow.tl` (the
simplified flow model), `_work/store.tl` (the git-backed store), and
`_work/gitboard.tl` (the CLI), with tests alongside. The ready-bar
section grammar is reused from `_work.model` unchanged; everything
else about the model gets SIMPLER here, and the section below on
dissolved carve-outs is the argument that the simplification is real.

## the shape

One repository (the "state repo" — in practice a new repo such as
`whilp/cosmic-work`) holds one file per item, with prose in a markdown
sidecar:

```
items/
  fast-startup.tl     a goal: ranked, long-lived
  make-cache.tl       an epic decomposing it
  stamp-env.tl        a slice an implementer pulls
  stamp-env.md        that slice's spec: the ready-bar sections
```

An item is `cosmic.literal` data — a file that can declare values and
nothing else:

```lua
return {
  ["claim"] = "session-a",
  ["id"] = "stamp-env",
  ["kind"] = "slice",
  ["opened"] = "2026-08-17T05:14:31Z",
  ["parent"] = "make-cache",
  ["phase"] = "check",
  ["pr"] = 1250,
  ["title"] = "stamp env deps into the graph",
  ["verdict"] = "request changes",
  ["verdict_head"] = "f00dcafe",
}
```

Zero values are omitted on write, so a fresh item is four lines and a
diff shows exactly what moved. Ids are slugs, not numbers: two
sessions creating items never race a counter, and `blocked_by` reads
as prose ("blocked_by = "fetch-retry docs-split"").

The hierarchy is structural, not prose convention:

- a **goal** carries a rank (1 is the top promise) and no parent —
  the committed, ranked outcome list that today lives in
  docs/goals.md;
- an **epic** carries `parent = <goal>`;
- a **slice** carries `parent = <epic or goal>` and is the ONLY kind
  with a phase; its spec sidecar carries the ready-bar sections
  (Goal/Change/Non-goals/Acceptance/Enablement — the same grammar,
  checked by the same `ready_gaps` function, over a file instead of an
  issue body);
- a **finding** is captured evidence: parentless and unphased until a
  planner adopts it into a slice or closes it.

`flow.trace_problems` checks the parent chain — a slice that reaches
no goal is a structural error the tool reports, not a missing prose
section a reviewer must notice.

Three properties fall out of "state is committed files":

- **git push is the compare-and-swap.** A mutation is
  commit-then-push. A rejected push means another session moved first;
  the store rebases onto the winner, re-asks the WIP invariant against
  the MERGED state, and drops its own commit if the limit now binds
  (`store.publish`). This is strictly stronger than the label board:
  GitHub's label index is eventually consistent, so the current tool
  documents a "pause and retry" ritual for spurious refusals and can
  double-admit under a race. The git board cannot.
- **git log is the flow record.** `stats` today reconstructs history
  by replaying label events through the GitHub timeline API, paginated
  and rate-limited, with a legacy-label table for renames. Here,
  `git log -- items/stamp-env.tl` IS the history — every transition,
  its time, and the session that made it, readable offline in
  milliseconds (`store.history`).
- **reads need no network and no token.** `status`, `tree`, and
  `next` are a directory scan after a `git pull`.

## the model gets simpler, measurably

The label board hangs everything on one issue list, so its WIP rule
needs four carve-outs (`model.admits_over_limit`): epics in plan do
not count, findings are never refused, `--mandated` filings are never
refused, and returns/accepts always pass. With the hierarchy
first-class, phase belongs to open slices only, and three of the four
dissolve structurally:

- an epic cannot crowd `plan` because an epic is never IN a phase;
- filing a finding cannot collide with a limit because a finding is
  never in a phase either;
- `--mandated` existed to push a required countermeasure past a full
  `plan`; a countermeasure is an unphased finding or a new slice
  decomposed later, so the flag has nothing left to force.

What remains is two lines: a return is never refused, and an accept
always lands. The goal trace stops being a prose section (`Goal:
G3...`) and becomes a parent edge the tool validates. The WIP limits
keep the empirically tuned values from `_work/model.tl` — the numbers
carry over; the exceptions do not, because the structures that needed
them are gone.

## what it looks like in practice

```
$ gitboard new goal fast-startup "binary startup under 20ms" --rank 1
$ gitboard new epic make-cache "cache the build graph" --parent fast-startup
$ gitboard new slice stamp-env "stamp env deps" --parent make-cache
gitboard-new: stamp-env enters plan

$ gitboard move stamp-env ready
  spec section missing or empty: Goal
  ...
gitboard-move: REFUSED: stamp-env misses the ready bar
$ gitboard spec stamp-env spec.md        # the refined spec, as markdown
$ gitboard move stamp-env ready
gitboard-move: stamp-env plan -> ready

$ gitboard tree
G1 fast-startup       binary startup under 20ms
  make-cache           [epic] cache the build graph
    stamp-env          [ready] stamp env deps
G2 learnable          a new agent ships in one session (no live work)
```

The implementer session is unchanged in shape: `next` names the pull,
`move stamp-env do --claim session-a` is the lock, the PR opens on
GitHub as before, `move stamp-env check` hands it to a planner. The
planner's verdict records on the item and the move it implies follows
in the same commit — accept is `check -> land`, request-changes is
`check -> do`, reject is `-> plan`. Intake stops being "walk
docs/goals.md by hand": `next --role planner` answers `intake
learnable — goal learnable (rank 2) has no live work`, because goals
and their live-work state are data.

Every mutation syncs first, gates against fresh state, commits, and
publishes; between sessions there is nothing to do.

## why literal files, not sqlite or markdown

- **sqlite** is a binary blob to git: no diffs, no merges, every
  concurrent write an unresolvable conflict. It buys queries a few
  hundred tiny files do not need and costs the one thing the design
  is for — reviewable, mergeable history.
- **markdown** is right for PROSE, so the spec lives in one; state
  read from markdown is a regex per field and a silent parse miss per
  hand edit. The split follows the content: coordination state in the
  literal file, refined spec in the sidecar.
- **`cosmic.literal`** is already the repo's answer for "data that
  must not be code": pins use it, the formatter has a fixpoint for
  it, and an item written through it is typed on the way in and
  validated on the way out (`item.problems` reports every defect of a
  hand-edited file at once). One file per item means two sessions
  touching different items NEVER conflict; two sessions touching the
  same item conflict exactly when they should.

## the side effect: an operations repo

Once the work system lives in its own repository, the machinery that
operates it wants to live there too. The state repo is an ordinary
cosmic project — `bin/cosmic` + pin, its own CI running `--make ci`
over the board tooling — and can absorb `_work/**`, `skills/work/**`,
and eventually the other repo-operations tooling (`agent-eval`, docs
publishing) that is about DEVELOPING cosmic rather than BEING cosmic.
cosmic then carries product only, and a WIP-limit tune stops being a
commit in the product's history. The cost is a second clone in every
session and a version-skew question, answered the way cosmic answers
it for itself: the ops repo pins cosmic, sessions run the ops repo's
checkout.

## pros and cons

Gained:

- no state comments on issues or PRs; GitHub surfaces stay
  human-facing
- goals, epics, slices, findings as one validated structure; the
  goal trace and the ready bar both checked by the tool
- real CAS on every mutation; the lagged-index refusal ritual goes away
- offline, tokenless, zero-API reads; history for free and complete
- a simpler flow model: the carve-outs dissolve instead of porting
- transitions carry provenance in commit messages without polluting
  any human-facing surface
- the ops-repo consolidation above

Lost or newly owned:

- **PR linkage is cross-system.** An item says `check` while its PR
  is already merged or closed. The design needs a reconciliation verb
  (`gitboard fsck`: cross-check open slices' `pr` fields against
  GitHub) run at session start — drift becomes detectable, but it
  exists. This is narrower than the label board's version of the
  problem (only the PR edge crosses systems now), but it is real.
- **visibility.** GitHub stops showing the board. Mitigations: a
  rendered board page in the docs publish; anything that makes labels
  load-bearing again is the trap to refuse.
- **write access.** Sessions need push rights to the state repo, and
  a runaway session could force-push history. Branch protection (no
  force pushes, linear history) answers most of it.
- **blockers only see items.** `is_blocked` consults items, not
  GitHub. Acceptable — the board reasons about state it holds — but a
  real semantic change.
- **one more clone, one more auth surface** in every session brief.

## what the spike shows, and does not

Shows: the codec round-trips every kind through the formatter's
fixpoint; phase discipline is enforced (only open slices are phased);
the hierarchy is validated structurally; the ready bar runs over spec
sidecars with the same section grammar as today; the board, pull
order, blocker skip, and planner intake all run from files; publish
resolves a genuine two-clone race over the `do` limit by refusing the
loser after rebase (`store_test.tl`); and the full lifecycle — goal,
epic, slice, spec, ready, claim, check, verdict, land, done — runs
end to end with history intact.

Does not show: GitHub reconciliation (`fsck`, a `land` verb that
merges the real PR, importing inbound issues as findings), the
`stats` port over `git log`, migration of the live board (a one-shot
import reading labels and writing items), or the ops-repo split.
Those are the follow-on slices if the direction holds.
