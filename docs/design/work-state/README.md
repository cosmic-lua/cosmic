# work state in a git repository

A design exploration, with a working spike: move the work system — its
coordination state, its hierarchy, and eventually its machinery — out
of GitHub labels and comments and into files committed under git.
Pull requests stay on GitHub and keep doing what they are good at: a
PR holds a diff, its CI, and its review conversation. Issues shrink to
an inbound queue — a bug report arrives there and is imported as a
finding — instead of being the board's storage. Nothing accumulates
claim comments, PR-link comments, or `work-verdict:` comments, because
no state lives where those comments used to put it.

The spike is `_work/ksuid.tl` (ids), `_work/item.tl` (the item codec),
`_work/flow.tl` (the flow rules), `_work/store.tl` (the git-backed
store), and `_work/gitboard.tl` + `_work/gitverbs.tl` (the CLI), with
tests alongside. The ready-bar section grammar is reused from
`_work.model` unchanged; everything else got SIMPLER, and the section
on emergent roles below is where most of the simplification comes
from.

## one record, no kinds: roles emerge from the graph

There is a single item record and no kind field. An item's role is its
position in the dependency graph — the same convention this repo
builds by, where a file's role is its position in the tree:

| position | role |
|----------|------|
| ranked root | a **goal**: long-lived, ordered by rank |
| unranked root | a **finding**: captured evidence, awaiting triage |
| parented, open children | a **container** being decomposed |
| parented leaf | **workable** — the only thing that holds a phase |

Roles change by changing the graph, never by editing a type tag:

- **decomposition is `attach`** (or `new --parent`). A workable item
  that gains a child stops being workable: the tool clears its phase
  in the same mutation, and it leaves the board. "Epic" is not a thing
  an item is; it is a thing an item is currently doing.
- **triage is `attach`, too.** A finding adopted under a goal becomes
  a workable leaf and enters `plan` — one operation, no marker labels,
  no kind rewrite. Ranking a root makes it a goal; closing it
  (`done --reason not-planned`) records the dead end.
- the goal trace is a checked property: every phased item must reach a
  RANKED root through its parent chain (`flow.trace_problems`), or the
  tool says which link is broken. No prose `Goal:` section to drift.

The label board's WIP rule needed four carve-outs (epics in plan do
not count; findings are never refused; `--mandated` filings are never
refused; returns/accepts always pass). Roots and containers are never
phased, so the first three have nothing to except; what remains of
`admits_over_limit` is two lines — a return is never refused, and an
accept always lands. The WIP limits keep the label board's empirically
tuned values; the exceptions go because the structures that needed
them went.

## ids are KSUIDs

An item's id is a KSUID: 4 bytes of timestamp + 16 random bytes,
base62-encoded to 27 characters (`_work/ksuid.tl`). Three properties
pay for the opacity:

- **no counter to race**: two sessions minting items never coordinate,
  where issue numbers came from GitHub's central sequence;
- **lexicographic order is creation order**: "oldest first" is a plain
  sort of ids — no `opened` field to drift from the truth;
- **stable across re-parenting**: a finding keeps its identity through
  adoption; history follows one file.

Verbs accept any unambiguous prefix (`gitboard show 3I1v4K`), the way
git accepts short hashes; ambiguity is reported with the candidates.

## the shape on disk

```
items/
  3I1v3H5UUa6WhTm6NutqYQYbwsC.tl    a ranked root — a goal
  3I1v3eb4z53ihA5kv6c9nLcoDF3.tl    under it, currently a container
  3I1v4KhH3u5mVU6gMEZbrfGcdvo.tl    a workable leaf, in plan
  3I1v4KhH3u5mVU6gMEZbrfGcdvo.md    that leaf's spec (ready-bar sections)
```

An item is `cosmic.literal` data — a file that can declare values and
nothing else; zero values are omitted, so a fresh item is two lines
and a diff shows exactly what moved. The spec prose lives in the
markdown sidecar, checked by the same `ready_gaps` section grammar the
label board applies to issue bodies. `move <id> ready` refuses a
hollow spec with the missing sections named.

Three properties fall out of "state is committed files":

- **git push is the compare-and-swap.** A mutation is
  commit-then-push. A rejected push means another session moved first;
  the store rebases onto the winner, re-asks the WIP invariant against
  the MERGED state, and drops its own commit if the limit now binds
  (`store.publish`). Strictly stronger than the label board, whose
  eventually-consistent index needs a "pause and retry" ritual and can
  double-admit under a race.
- **git log is the flow record.** `git log -- items/<id>.tl` is the
  item's history — every transition, its time, its session — readable
  offline in milliseconds. The `stats` timeline-replay machinery
  becomes a log walk.
- **reads need no network and no token.** `status`, `tree`, `next`
  are a directory scan after a `git pull`.

## a branch of cosmic, not a second repository

The state does not need its own repository: it needs its own HISTORY.
A dedicated branch of whilp/cosmic — `work`, created orphan like the
`docs` branch, holding `items/**` and, once the direction settles, the
machinery (`_work/**`, `skills/work/**`) — gives it that, and a
session reaches it as a second worktree of the clone it already has:

```
git worktree add o/board board    # once per checkout; o/ is already ignored
gitboard status --dir o/board    # every verb takes the worktree as --dir
```

No second clone, no second credential, no new repo to administer:
pushing `work` uses the same remote and the same auth as pushing a
topic branch, and the push-CAS works identically on a branch. The
machinery moves out of main's history (a WIP-limit tune stops being a
product commit) without leaving the repository.

One discipline makes it sound: **the work branch is append-only —
never rebased, never force-pushed.** Rebasing published state history
re-writes commits other sessions have built on; every clone's CAS
assumptions break at once. This also answers "periodically rebase onto
main": don't — the branch shares no files with main, so there is
nothing to reconcile, and an orphan history stays permanently
disjoint. The one moving part is the toolchain: the work branch pins
cosmic through its own `bin/cosmic.pin` like any cosmic project, and
bumping that pin is how it tracks the product. (If sharing history
with main is ever wanted, `git merge main` preserves the state
commits; rebase is the one operation the design forbids.)

Costs, honestly: pushes to `work` show up in the repository's activity
and must be excluded from CI triggers (a one-line branch filter in the
workflows); branch protection needs configuring for one branch rather
than a repo; and a runaway session with push rights to the repo could
still force-push it — the same protection rule (no force pushes,
linear history) answers it.

## what it looks like in practice

```
$ gitboard new "binary startup under 20ms" --rank 1
gitboard-new: 3I1v3H5U... enters goal, rank 1
$ gitboard new "cache the build graph" --parent 3I1v3H
gitboard-new: 3I1v3eb4... enters plan            # a parented leaf: workable
$ gitboard new "stamp env deps" --parent 3I1v3e
gitboard-new: 3I1v4KhH... enters plan
$ gitboard show 3I1v3e | head -2                  # gaining a child de-phased it
role: container
$ gitboard tree
G1 3I1v3H5U binary startup under 20ms
  3I1v3eb4 [container] cache the build graph
    3I1v4KhH [plan] stamp env deps
```

The session loops keep their shape. Implementer: `next` names the
pull, `move 3I1v4K do --claim session-a` is the lock, the PR opens on
GitHub as before, `move 3I1v4K check` hands it over. Planner: `next
--role planner` orders verdicts first, then refining plan items toward
ready (the spec sidecar plus `check`), then triaging findings —
`attach <finding> <parent>` adopts one into plan in a single move —
then intake, which names the top-ranked goal with no live work under
it. A verdict records on the item and the move it implies follows in
the same commit; nothing is posted anywhere.

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
  touching different items NEVER conflict; two touching the same item
  conflict exactly when they should.

## pros and cons

Gained:

- no state comments on issues or PRs; GitHub surfaces stay
  human-facing
- one record, no kinds: roles, adoption, and decomposition are graph
  operations the tool can check, not conventions a reviewer must
  notice
- goals live IN the system: ranked items, so intake is computed
- real CAS on every mutation; ids without a central counter; history
  for free; offline tokenless reads
- state and machinery consolidated on a branch of the repo that
  already exists, reachable as a worktree

Lost or newly owned:

- **PR linkage is cross-system.** An item says `check` while its PR
  is already merged. A reconciliation verb (`gitboard fsck`
  cross-checking `pr` fields against GitHub) run at session start
  makes drift detectable; it cannot make it impossible.
- **visibility.** GitHub stops showing the board; ids are opaque
  where issue numbers were memorable. Mitigations: `tree`/`status`
  are one command with no token, and a rendered board page can ride
  the docs publish. Anything that makes labels load-bearing again is
  the trap to refuse.
- **intent is inferred, not declared.** A leaf meant for further
  decomposition looks workable until its children exist. The phase
  mechanism absorbs this — nothing is pullable until a planner moves
  it to `ready` past the spec bar — but "this will be an epic" now
  lives in the planner's head or the spec text, not in a field.
- **blockers only see items.** `is_blocked` consults items, not
  GitHub. Acceptable — the board reasons about state it holds — but a
  real semantic change.

## what the spike shows, and does not

Shows: KSUIDs whose lexicographic order is creation order, with
prefix resolution in every verb; one kind-less record whose roles
derive from the graph; decomposition and triage as `attach`, with the
de-phase-on-decompose mechanic live; the ready bar over spec sidecars
with the label board's own section grammar; the goal trace as a
checked graph property; the board, pull order, blocker skip, finding
triage, and goal-aware intake all running from files; and publish
resolving a genuine two-clone race over the `do` limit by refusing
the loser after rebase (`store_test.tl`).

Does not show: GitHub reconciliation (`fsck`, a `land` verb that
merges the real PR, importing inbound issues as findings), the
`stats` port over `git log`, migration of the live board, or actually
cutting the `work` branch and moving the machinery onto it. Those are
the follow-on slices if the direction holds.
