# board

The board branch: cosmic's board and the machinery that operates it,
together, on an orphan history. This branch shares no files with
`main` — it is append-only, never rebased, never force-pushed;
rewriting published state history would break every checkout's
push-as-compare-and-swap at once.

## What lives here

```
items/       the board: one <ksuid>.tl per item (cosmic.literal data)
             with its spec prose in the matching <ksuid>.md; every verb
             and render addresses it by the 8-character handle (bare or
             wrapped, either divider, case-tolerant) or an unambiguous prefix
_work/       the machinery: gitboard (CLI), gitverbs (mutations),
             gitcompare (the priority relation as a verb), gitview
             (reads), gitgate (the spec bar, the doing bound, and the
             commit-and-publish every mutation goes through), store
             (git-backed persistence), flow (the derived states and
             graph rules), priority (the comparison relation and the
             order derived from it), spec (the spec bar's section
             grammar), item (the record), ksuid (ids)
cmd/gitboard the binary this branch builds: `o/bin/gitboard`
bin/cosmic   the trust root: fetches the one pinned cosmic and execs it
```

A workable item's state is DERIVED from the facts its file carries,
never declared: open, unclaimed, and PR-less is `todo` (pullable once
its spec passes the bar `show ID` prints); a claim or a PR makes it
`doing`; a resolution ends it. Which claim a `take` makes is derived
the same way — an item awaiting a verdict, taken by a session that is
not its builder, is the review claim. Within doing the same facts say what happens
next — building, awaiting review, rework, accepted. One WIP bound,
`_work/flow.tl`'s `DOING_LIMIT`, covers the whole in-flight span:
taking NEW work is refused at the limit, finishing motions never
are.

Roles derive from the graph — there is no kind field and no goal
tier: an item with open children is a container being decomposed, a
parentless one is a root, and a parented leaf is workable (the only
thing with a board state).

Which items matter more is a RELATION, not a number an item asserts
about itself. `compare A B` commits one judgment — A outranks B — as
an edge on the winner, and `_work/priority.tl` derives every order
from the accumulated edges: transitivity closes the pairs nobody was
asked about, a comparison at any height places everything beneath it,
and age is the last word among items no comparison separates. An item
no edge reaches, at any height, is UNPLACED, and that is exactly what
the triage queue holds; `take` refuses work with no position, so an
unplaced item is never pulled. A cycle
is reported, never averaged away: it means the comparison question was
ambiguous, so the pair is restated and re-asked.

The outcome prose those roots stand for lives in `docs/goals.md` on
`main`. It is context a planner reads to interpret and adjust the
tree — nothing here derives from it, and nothing checks it.

What the verbs ARE lives here and only here: `gitboard help` lists
them, `gitboard help <verb>` gives one its options, and both are
generated from the CLI, so neither can drift from the tool. The
SYSTEM lives here too: `gitboard help <topic>` serves the doctrine
pages (`_work/doctrine.tl`) — the states and their exits, the spec
bar, building, review, orchestration — and `gitboard brief` emits
the subagent prompts with the board's own facts filled
(`_work/brief.tl`), so a brief cannot drift from the item it is
about. The `work` skill on `main` is only the bootstrap: it points
here and restates none of this, so a verb, topic, or brief changed
here needs no edit there and reaches every session on its next
sync.

## Using it from a cosmic checkout

The machinery lives HERE, not on main, so the verbs run from this
worktree — `--dir` then defaults to it and needs no argument:

```
git worktree add o/board board     # once per checkout
cd o/board
bin/cosmic --make build            # once, on a cold worktree
o/bin/gitboard show
o/bin/gitboard next
```

`o/bin/gitboard` is an ordinary cosmic binary carrying `_work/**`, so
a verb is one process and its output is only the verdict line. Before
the branch has built, `bin/cosmic --make run _work/gitboard.tl <verb>`
runs the same CLI through make.

Building a binary is not the same as building the TOOLCHAIN. A gate
re-execs into what the tree built only for a project that defines
`cosmic/**` and ships a binary called `cosmic`; this branch does
neither, so every `--make` verb here runs under the pinned release.
The pin therefore decides which fence the tests execute inside, which
is why `bin/cosmic.pin` matters here beyond reproducibility.

Every mutation is ONE commit here, and publishing it is a push. A
rejected push is the compare half of a compare-and-swap FAILING: the
mutation's gates were decided against a board somebody else just
moved, so the tool drops its own commit whole, re-syncs onto the
winner's state, and refuses, naming the recovery — run the same verb
again, and it decides afresh with EVERY gate applied to the merged
board, not a replayed commit whose preconditions may no longer hold.
A mutation never half-lands, and the checkout is always left clean
and current. Reads need no network and no token.

A mutation syncs by `git fetch` plus a fast-forward-only merge, which
tolerates an unrelated dirty file anywhere in the checkout and only
refuses, naming the file, when a local edit overlaps the incoming
commit — so a session editing `_work/**` here does not lock every
other session sharing this worktree out of the board. That slice of
work still belongs in its OWN clone, though: `git worktree add` (or a
plain `git clone`) plus `--dir` is how the machinery itself gets
edited, built and tested without racing the mutations running against
the shared checkout. And `git stash` is never the escape here — the
stash stack is shared across every worktree of this repo, so a push
from one session can pop and destroy another session's in-progress
edit; reach for a private clone instead.

Run `bin/cosmic --make ci` before pushing machinery changes; the
`board` workflow runs the same gate on every push to this branch.

**`.cosmic-coverage` is recorded in the `board` workflow's `ci` job**
(`.github/workflows/board.yml`: a plain `ubuntu-latest` runner, no
pinned container, no elevated privilege — this branch's own tests need
neither), not in a developer's clone or worktree. The coverage
machinery itself lives on `main` (`_make/policy.tl`, embedded in
whatever release `bin/cosmic.pin` here resolves to), not in this tree,
so `--make coverage --baseline` run from a private clone still rewrites
the whole floor with THIS machine's measurement — nine rows on five
files a change never touched, on one reported run, none of them in the
diff. Prefer hand-editing the one row your change actually moved
(`covered`/`total` in `.cosmic-coverage`) over running `--baseline`
here at all; once `bin/cosmic.pin` carries a release built from a
`main` that refuses `--baseline` outside `COSMIC_COVERAGE_ENV=1`
(cosmic-lua/cosmic's `AGENTS.md` coverage paragraph), the same refusal
applies here automatically, and `board.yml`'s `ci` job already sets
that marker for itself so a whole-floor rewrite stays possible from
the one place it should be.

GitHub keeps two jobs: pull requests carry fixes and their review;
issues are the inbound queue, imported here as findings at triage.
