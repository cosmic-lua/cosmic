## Goal

G8 — the flow system. Let a board mutation land while the shared board
worktree carries unrelated uncommitted changes under `_work/**`, so a
session slicing the MACHINERY does not lock every concurrent session out
of the BOARD.

Today one session editing `_work/**` in `/home/user/cosmic/o/board`
disables `new`, `attach`, `block`, `unblock`, `spec`, `move`, `verdict`,
`done`, `review`, `land`, `compare`, `uncompare` and `next --take` for
every session sharing that worktree, for as long as the edit is
uncommitted. The two escapes sessions actually found were `git stash`
(unsafe here — the stash stack is shared repo-wide, verified below) and a
private clone driven with `--dir` (safe, but undocumented and discovered
ad hoc).

The mutation's own commit never contains `_work/**`. The block comes
from the sync step's `git pull --rebase`, which is a whole-tree
operation and refuses on any unstaged change at any path.

## Evidence

Measured 2026-08-29 against `board` at `53f77346`, using the built
`o/bin/gitboard` from `/home/user/cosmic/o/board` and an isolated
clone so the shared worktree was never dirtied. Every command below
was run; the shared worktree's `git status --porcelain` was empty
before and after.

**Where the refusal comes from.** `_work/store.tl:317`
`rebase_onto_remote` runs `git pull -q --rebase origin`;
`_work/store.tl:343` `sync` is its only wrapper;
`_work/gitboard.tl:190` calls `store.sync` for every command in the
`MUTATES` set (`_work/gitboard.tl:57`), and `_work/gitboard.tl:212`
again for `next --take`. `_work/gitverbs.tl:358` is the bare `sync`
verb.

**The verbatim refusal, reproduced.** In a clone of `board` with one
modified `_work/*.tl` and nothing to pull:

```
$ echo "-- scratch edit" >> _work/flow.tl
$ git pull -q --rebase origin
error: cannot pull with rebase: You have unstaged changes.
error: Please commit or stash them.
exit=128
```

Through the tool, same tree:

```
$ o/bin/gitboard sync --dir CLONE
gitboard-sync: git pull --rebase failed: error: cannot pull with rebase: You have unstaged changes.
error: Please commit or stash them.

$ o/bin/gitboard new "scratch reproduction probe" --dir CLONE
gitboard-new: could not sync before mutating: git pull --rebase failed: error: cannot pull with rebase: You have unstaged changes.
error: Please commit or stash them.
```

Both exit 1. The reported text is confirmed verbatim. The report's
attribution is also confirmed: the message is git's, surfaced through
`rebase_onto_remote`'s fallback branch, not a gate of the board's own.

**Reads are unaffected.** `gitboard status --dir CLONE` on the same
dirty tree exits 0. Only `MUTATES` verbs and `next --take` sync.

**The refusal fires with nothing to pull.** The clone above was
level with `origin`; the refusal is unconditional on tree state, not a
consequence of incoming work.

**A mutation commits `items/**` and nothing else.** `_work/store.tl`
`stage` (line 209) `git add`s exactly `items/<id>.tl` and, when
present, `items/<id>.md`. With the same tree cleaned:

```
$ o/bin/gitboard new "scratch reproduction probe" --dir CLONE
gitboard-new: 3IZqut2SUTkz4No3jttZwYFulq8 enters triage — attach it under something, or compare it
$ git show --stat --oneline HEAD
950dea12 new 3IZqut2S scratch reproduction probe
 items/3IZqut2SUTkz4No3jttZwYFulq8.tl | 4 ++++
 1 file changed, 4 insertions(+)
```

**Paths are disjoint in practice.** Over the last 300 commits on
`board`: 298 touch `items/`, 2 touch `_work/`, 0 touch both.

```
$ git log -300 --format='%H' | while read c; do n=$(git show --name-only --format= $c); ...
commits=300 touching items/=298 touching _work/=2 touching both=0
```

So a mutation's commit content and a machinery slice's dirt are
disjoint by construction, and incoming commits overlap a machinery
slice's paths rarely but not never — the 2 are exactly the collision
case.

**The stash escape is as dangerous as reported — verified.**
`refs/stash` is per-repository and shared across linked worktrees, and
`/home/user/cosmic/o/board` is a linked worktree
(`.git` is `gitdir: /home/user/cosmic/.git/worktrees/board`;
`git rev-parse --git-common-dir` is `/home/user/cosmic/.git`). In a
repo with two worktrees A and B:

```
A$ git stash push -m "session A in-progress _work edit"
A$ git stash list  -> stash@{0}: On board: session A in-progress _work edit
B$ git stash list  -> stash@{0}: On board: session A in-progress _work edit
B$ git stash pop   -> Dropped refs/stash@{0} (57bb4312...)
B$ git status --porcelain -> " M _work/flow.tl"
A$ git status --porcelain -> (empty)
```

Session B popped session A's in-progress work into B's tree and A lost
it. Any documented remedy must steer away from `stash`.

**A second, worse hazard the clean-tree requirement is currently
masking.** `_work/store.tl:398` `publish` recovers a lost push race with
`git reset -q --hard HEAD~1`. That is a whole-tree reset and it
silently destroys uncommitted work at unrelated paths:

```
$ echo "-- precious uncommitted work" >> _work/flow.tl
$ git reset -q --hard HEAD~1
$ git status --porcelain   -> (empty; the edit is gone)
```

Reachable today only because sync refuses first. Any relaxation of the
sync gate exposes it, so the reset must be narrowed in the same change.

**Autostash is viable but not sufficient alone.** `git rebase
--autostash origin/board` on a tree with dirty `_work/flow.tl` and an
incoming `items/`-only commit rebases, re-applies the edit, and leaves
`git stash list` EMPTY — it does not use the shared stack. But when the
incoming commit touches the SAME path:

```
Created autostash: 1681da6e
Applying autostash resulted in conflicts.
Your changes are safe in the stash.
Successfully rebased and updated refs/heads/board.
$ git status --porcelain -> UU _work/flow.tl
$ git stash list         -> stash@{0}: autostash
```

In the overlap case autostash leaves conflict markers in the machinery
AND pushes an entry onto the shared stash stack — the exact hazard this
item exists to remove. Autostash alone is therefore not the answer.

**Untracked files do not block.** A tree whose only change is an
untracked `_work/UNTRACKED.tl` pulls cleanly (exit 0). Staged-but-
uncommitted changes block with a different message: `error: cannot pull
with rebase: Your index contains uncommitted changes.`

**What did not hold up in the report.** Two corrections. (a) The
refusal is not merely incidental: it is currently the only thing
standing between a dirty `_work/**` tree and `publish`'s destructive
`reset --hard HEAD~1`. Removing the clean-tree requirement without
narrowing that reset makes things worse, not better. (b) The
"disjoint paths" premise is true of commit CONTENT (stage is
pathspec-explicit) and true of history in practice (0 of 300 commits
touch both), but it is not a guarantee — `_work/**` commits do land on
this branch, so a sync that must apply one over local `_work/**` dirt
is a real, if rare, case that any fix has to answer rather than assume
away.

The two workarounds as reported are otherwise consistent with what the
sources and the reproduction show: the stash route is live-fire
dangerous, and `--dir` against a private clone bypasses the shared
worktree entirely and is safe.

## Change

Make a board mutation independent of the shared worktree's state at
paths it does not own, without weakening the publish race.

The direction to shape, in preference order:

1. **Take the working tree out of the mutation path.** Sync by
   `git fetch` plus a rebase that never touches the checkout, and stage
   and commit `items/**` through a private index (`GIT_INDEX_FILE` +
   `git update-index` + `git commit-tree`), so a mutation reads and
   writes only its own two files and the ref. This is the only direction
   that is correct in the overlap case as well as the common one, and it
   removes the shared-stash and `reset --hard` hazards together rather
   than trading one for the other. Narrow `publish`'s lost-race recovery
   from `reset --hard HEAD~1` to a ref-only move in the same change.
2. **Autostash as a smaller step**, accepted only with the overlap case
   handled: refuse rather than leave `UU` markers and a shared-stack
   entry behind. Evidence above shows the failure mode concretely.
3. **An actionable refusal.** Whichever mechanism lands, a mutation that
   still cannot proceed should say what to do — name the dirty paths and
   point at `--dir <private clone>` — instead of relaying git's raw
   `cannot pull with rebase` text, which names `stash` as a remedy and
   is wrong here.
4. **Write the rule down.** The branch `README.md` (and, if it is the
   better home, the `work` skill) should say that a `_work/**` slice
   runs in its own clone, and that `git stash` is never the escape in
   this repo because the stack is shared across worktrees.

What this does NOT solve, stated plainly: it does not make two sessions'
concurrent `_work/**` edits safe — two machinery slices in one worktree
still collide, and the answer there stays one clone per slice. It does
not remove the need for a private clone when a slice must BUILD the
machinery it is editing (the built `o/bin/gitboard` is the tool the
session is also using). It does not change the push race or its
recovery semantics — only the mechanism by which the recovery is
performed. And a rebase that genuinely must apply an incoming
`_work/**` commit over local `_work/**` dirt is still a conflict a
human resolves; the fix makes it a clean refusal, not a resolved merge.

## Non-goals

- **Do not weaken the compare-and-swap publish.** The push-as-CAS in
  `_work/store.tl` `publish` — reject, diagnose, drop the whole
  mutation, re-sync, refuse with `LOST_RACE` — is the existing and
  correct mechanism for two sessions writing `items/**` concurrently.
  It stays. Narrowing HOW the drop is performed is in scope; changing
  WHETHER a lost race drops the mutation is not.
- **Do not let a mutation skip validation.** Every gate — WIP, ready
  bar, priority placement, claim, `item.problems` — still runs against
  the merged board before the commit is made. A mutation that cannot
  sync must refuse, not proceed on stale state.
- **Do not make `--force` the answer.** `--force` is for a judged
  exception to a board rule, not for a dirty checkout.
- **Do not introduce `git stash` anywhere in the machinery.** The stack
  is shared across every worktree of this repo; the machinery must never
  push to it, and the docs must never recommend it.
- **No change to the one-mutation-one-commit rule.** `save` writing
  exactly one commit is what makes the race recovery exact.
- Not a change to reads. They already work on a dirty tree.

## Acceptance

- With `_work/**` modified in a checkout, every `MUTATES` verb and
  `next --take` either completes normally or refuses with a message that
  names the dirty paths and the `--dir` remedy. Neither outcome leaves
  the working tree changed at any path the mutation does not own, and
  neither adds an entry to `refs/stash`. Demonstrated by a test that
  dirties a `_work/*.tl` in a fixture checkout, runs a mutation, and
  asserts the commit's `--name-only` is exactly the item's files, the
  dirty file's content is byte-identical afterwards, and `git stash
  list` is empty.
- A lost push race with a dirty `_work/**` tree drops the mutation and
  leaves the dirty file's content byte-identical. This is the
  regression test for the `reset --hard` hazard; it fails against the
  current `publish`.
- A sync that must apply an incoming `_work/**` commit over an
  overlapping local `_work/**` edit refuses with a message naming the
  file, and leaves no conflict markers and no stash entry.
- Existing behaviour unchanged: `publish_race_test.tl` and
  `gitclaim_test.tl` pass; a lost race still refuses `LOST_RACE`; reads
  still need no network.
- `README.md` states the `_work/**`-slice-in-its-own-clone rule and that
  `stash` is not an escape in this repo.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

No blocker. Everything the change touches is on this branch:
`_work/store.tl` (`sync`, `rebase_onto_remote`, `stage`, `save`,
`publish`), `_work/gitboard.tl` (the `MUTATES` dispatch), and
`README.md`. The tests have an existing home in
`_work/store_test.tl` and `_work/publish_race_test.tl`, and
`_work/fixture.tl` already builds throwaway checkouts.

Because this IS a `_work/**` slice, the session that implements it must
run in its own clone of `board` and drive the verbs with `--dir` — the
very workaround this item exists to remove.

Sits beside two siblings under G8 and duplicates neither.
`3IZZ1icV` is about the HANDOVER model — a slice that lands by direct
push to `board` has no commit-carrying form to reach `check` with; that
is about how board-branch work is reviewed, not about whether its
mutations can run. This item is about the MUTATION path being blocked
while such a slice is in flight. They compound — a `_work/**` slice
today is blocked mid-flight by this, then has no clean door into
`check` by `3IZZ1icV` — but the fixes are disjoint.
`3IZaO4Vj` (in `check`) is stale PROSE in the machinery describing a
deleted gate; this is live BEHAVIOUR of the sync path. `3IZaO4Vj` is
also the slice whose fifteen-minute dirty window produced the evidence
above, which is how the two are related and all they share.
