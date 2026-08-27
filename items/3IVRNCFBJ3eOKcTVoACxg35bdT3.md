## Evidence

`gitboard verdict` records `verdict_head` — the commit a review judged
— and refuses from any phase but `check`. So a `verdict_head` that is
wrong when recorded cannot be corrected by any verb: the item has
already moved to `land`, `do` or `backlog` by the time anyone notices.

Hit for real on 3IVKVslE, 2026-08-27. The reviewing session recorded
`d8fb3612fac03a6601c6e0ed084c9cb93ad990f4`, which is a **board commit**
(`spec 3IHHKCyz`) with no relation to PR 1465 —
`git merge-base --is-ancestor` against the real head returns
not-related. The cause was reading `git rev-parse FETCH_HEAD` in a
worktree whose `FETCH_HEAD` had been left by an unrelated fetch, rather
than the head the PR reports. The judged head was `9195ae29`.

Corrected by the file-edit workaround the skill sanctions for a
missing verb (board commit `0b2b4a0d`), which is why this item exists.

**Why a wrong `verdict_head` matters rather than being cosmetic.**
`review.md` makes it the re-review signal: "the item's `verdict_head`
records which commit was judged, so a reviewer can see at a glance
whether anything new followed the verdict — read it before re-reviewing,
and treat an unmoved head as nothing to judge." A field pointing at an
unrelated commit always compares unequal, so a re-reviewer is told
there is something new to judge when there may not be — or, worse, a
field that accidentally matches would say the opposite.

## What this item should settle

1. **Whether a correction verb is warranted at all**, or whether the
   right fix is upstream: have `verdict` take the PR number it already
   receives and read the head from GitHub itself, so no session can
   record a head it typed. That removes the class rather than adding a
   repair for it, and `move ... check --pr N` already proves the tool
   can reach the API.
2. If a verb is still wanted, its shape: a narrow `verdict --amend-head`
   usable from `land`/`do`/`backlog`, versus widening the general
   escape hatch. Prefer the narrow one — a general "edit any field"
   verb would undo the guarantee that phases move only through checked
   transitions.
3. Whether anything else records a caller-supplied sha that the tool
   could derive instead. `--pr` is derived from nothing today either,
   but a wrong PR number fails loudly at the API; a wrong sha does not.

Option 1 is the one worth weighing first: it is the only one that makes
the error impossible rather than repairable.
