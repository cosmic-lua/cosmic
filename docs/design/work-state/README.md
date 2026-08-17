# work state in a git repository

A design exploration, with a working spike: move the work system's
coordination state — phases, claims, verdicts, the transitions — out of
GitHub labels and comments and into files committed in a git
repository. Issues and pull requests stay on GitHub and keep doing what
they are good at: an issue holds a problem statement and its refined
spec, a PR holds a diff, its CI, and its review conversation. What
neither holds anymore is workflow state, so neither accumulates the
claim comments, PR-link comments, and `work-verdict:` comments that
today exist only to make state legible to the board tool.

The spike is `_work/card.tl` (the card codec), `_work/store.tl` (the
git-backed store), and `_work/gitboard.tl` (the CLI), with tests
alongside. `_work/model.tl` — every flow rule the system has — is
untouched and shared by both backends, which is the load-bearing fact
of the design: the policy was already separated from the state backend,
so the backend can be swapped under it.

## the shape

One repository (the "state repo" — in practice a new repo such as
`whilp/cosmic-board`) holds one file per card:

```
cards/
  1201.tl        the coordination state of whilp/cosmic#1201
```

A card is `cosmic.literal` data — a file that can declare values and
nothing else:

```lua
return {
  ["claim"] = "session-a",
  ["issue"] = 1201,
  ["phase"] = "check",
  ["pr"] = 1250,
  ["title"] = "gitboard: card codec over cosmic.literal",
  ["verdict"] = "request changes",
  ["verdict_head"] = "f00dcafe",
}
```

Zero values are omitted on write, so a fresh card is three lines and a
diff shows exactly what moved. The card carries only what MOVES:
phase, markers (epic/finding/enable), blockers, claim, PR link,
verdict, resolution. The spec (Goal/Change/Non-goals/Acceptance) stays
in the issue body; the diff and review stay on the PR.

Three properties fall out of "state is committed files":

- **git push is the compare-and-swap.** A mutation is
  commit-then-push. A rejected push means another session moved first;
  the store rebases onto the winner, re-asks the WIP invariant against
  the MERGED board, and drops its own commit if the limit now binds
  (`store.publish`). This is strictly stronger than today's board: the
  GitHub label index is eventually consistent, so the current tool
  documents a "pause and retry, never `--force`" ritual for spurious
  refusals and can double-admit under a race. The git board cannot.
- **git log is the flow record.** `stats` today reconstructs history
  by replaying label events through the GitHub timeline API, paginated
  and rate-limited, with a legacy-label table for renames. Here,
  `git log -- cards/1201.tl` IS the history — every transition, its
  time, and the session that made it, readable offline in
  milliseconds (`store.history`).
- **reads need no network and no token.** `status` and `next` are a
  directory scan after a `git pull`. A planner can read the whole
  board, every card, and every card's history from one clone — the
  N-API-call `show` of today becomes zero calls.

## what it looks like in practice

The session loops do not change; the verbs keep their names and their
verdict lines. An implementer session against the spike:

```
$ gitboard next
gitboard-next: pull #1201 card codec over cosmic.literal — oldest ready issue with no open blocker
$ gitboard move 1201 do --claim session-a
gitboard-move: #1201 ready -> do
  ... implement, open the PR on GitHub as before ...
$ gitboard move 1201 check
gitboard-move: #1201 do -> check
```

A planner session:

```
$ gitboard next --role planner
gitboard-next: review #1201 — check is the rightmost planner phase — verdicts first
  ... read the PR diff on GitHub, judge it ...
$ gitboard verdict 1201 accept --pr 1250 --head f00dcafe
gitboard-verdict: accept on #1201: check -> land
```

The verdict records on the card and the move it implies follows in the
same commit — accept is `check -> land`, request-changes is
`check -> do`, reject is `-> plan`, and none of them posts a comment
anywhere. The card's whole life is then:

```
$ git log --oneline -- cards/1201.tl
6bf6694 done #1201 completed (from land)
d79e26e verdict #1201 accept (check -> land)
0c70a69 move #1201 do -> check
692d806 move #1201 ready -> do
069ac86 new #1201 card codec over cosmic.literal (ready)
```

Every mutation runs `sync` (pull --rebase) first, gates against the
fresh board, commits, and publishes. Between sessions there is nothing
to do: the next session's first `sync` picks up everything.

## why literal files, not sqlite or markdown

- **sqlite** is a binary blob to git: no diffs, no merges, every
  concurrent write a conflict that cannot be resolved textually. It
  buys queries the board does not need (the whole board is a few
  hundred tiny files) and costs the one thing the design is for —
  reviewable, mergeable history.
- **markdown** is legible but parsed by convention; every field read
  is a regex and every hand edit a potential silent parse miss. The
  board's state deserves the same rigor as a pin.
- **`cosmic.literal`** is already the repo's answer for "data that
  must not be code": pins use it, `--make fetch` reads it, the
  formatter has a fixpoint for it, and a card written through it is
  typed on the way in and validated on the way out (`card.problems`
  reports every defect of a hand-edited card at once). One file per
  card means two sessions touching different cards NEVER conflict;
  two sessions touching the same card conflict exactly when they
  should.

## the side effect: an operations repo

Once coordination state lives in its own repository, the machinery
that operates it wants to live there too. The state repo is an
ordinary cosmic project — `bin/cosmic` + pin, its own CI running
`--make ci` over the board tooling — and can absorb:

- `_work/**` (the board tool and its tests),
- `skills/work/**`, and the session-loop docs,
- eventually `skills/agent-eval`, `_docs/` publishing, and other
  repo-operations tooling that is about DEVELOPING cosmic rather than
  BEING cosmic.

cosmic itself then carries product and product conventions only, and a
board-tool change stops showing up as noise in the product's history —
today a WIP-limit tune is a cosmic commit. The cost is a second clone
in every session and a version skew question (which board tool version
is a session running?), answered the same way cosmic answers it for
itself: the ops repo pins cosmic, sessions run the ops repo's checkout.

## pros and cons

Gained:

- no state comments on issues or PRs; issue bodies stay spec-only
- real CAS on every mutation; the lagged-index refusal ritual goes away
- offline, tokenless, zero-API reads; `next` in milliseconds
- history for free, complete and local (`stats` becomes `git log` replay)
- typed, validated, reviewable state; a bad transition is a revert
- transitions can carry provenance (session, reason) in commit messages
  without polluting any human-facing surface
- the ops-repo consolidation above

Lost or newly owned:

- **two sources of truth.** A card says `check` while the PR is
  already merged, or an issue is closed with its card still open.
  Today the label rides the issue, so state and artifact cannot drift
  apart silently. The design needs a reconciliation verb (`gitboard
  fsck`: cross-check cards against issue/PR state) run at session
  start — drift becomes detectable, but it exists.
- **visibility.** The GitHub issue list stops showing phases; a human
  browsing issues sees no board. Mitigations: a rendered board page in
  the docs publish, or a single mirrored label maintained best-effort —
  but the moment labels are load-bearing again the design is lost.
- **write access.** Sessions need push rights to the state repo, and a
  runaway session can now force-push history. Branch protection on the
  state repo (no force pushes, linear history) is cheap and answers
  most of it.
- **blockers only see cards.** `is_open` consults cards, not GitHub,
  so a blocker tracked only as an issue does not block until it is
  carded. Acceptable (board reasons about board state) but a real
  semantic change.
- **one more clone, one more auth surface** in every session and every
  brief.

## what the spike shows, and does not

Shows: the codec round-trips through the formatter's fixpoint; the
store enforces validity on save; the board groups and the model's
pull order, epic exemption, WIP gates, and blocker grammar all apply
unchanged (`card.to_issue` renders `blocked_by` in the model's own
"Blocked by: #N" grammar); publish resolves a genuine two-clone race
over the `do` limit by refusing the loser after rebase
(`store_test.tl`); and the full lifecycle — new, pull, claim, check,
verdict, land, done — runs end to end with history intact.

Does not show: GitHub reconciliation (`fsck`, `land` actually merging
a PR, closing an issue when its card ends), the `stats` port,
migration of the live board (a one-shot import reading today's labels
and writing cards), or the ops-repo split. Those are the follow-on
slices if the direction holds.
