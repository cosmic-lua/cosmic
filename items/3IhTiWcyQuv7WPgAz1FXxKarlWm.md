## Question

Item `3I1JDVLm` (handle «kxK7_MuJk», "one regen verb for every committed
floor, and every ratchet failure names it") has a `## Change` bullet 4
that names `skills/work/decompose.md` as a file to update: "Update
CLAUDE.md's testing section and `skills/work/decompose.md`'s ratchet
clause — it already tells a slice to 'run exactly the regen command the
gate's failure message prints'."

## Evidence

Measured 2026-08-31 against `main`, in a fresh worktree at
`/home/user/wave9/kxK7_MuJk`, branch `3I1JDVLm`, commit `5979c511`
(the rest of the item's `## Change` built and verified there):

- `git log --oneline -- skills/work/decompose.md` on `main`'s ancestry
  returns nothing — the file does not exist anywhere in `main`'s
  history.
- `skills/work/SKILL.md` at `main` HEAD states explicitly: "the system
  lives in the tool, not here... do not act from memory of an older
  version of this skill: read the tool's pages" — the doctrine bullet
  4 wants updated has been migrated entirely into the `gitboard` tool
  on the orphan `board` branch, which is out of scope for a `main`
  PR and, per the standing builder brief, out of a builder's authority
  ("Do NOT run any `gitboard` command — board state is the
  orchestrator's job").

So bullet 4 names a file that has no counterpart to edit in the repo
tree a `main`-targeted PR touches.

## What needs deciding

Bullet 4 needs either:
- dropping (the doctrine bullet 4 wants stated has already migrated to
  the tool's own help text on `board`, and needs no `main`-side edit),
  or
- retargeting to wherever the equivalent doctrine now actually lives
  for a `main` reader (if anywhere) — a planning pass should check
  whether the intent is still worth stating somewhere `main` readers
  see, or whether the migration to `gitboard help` fully subsumed it.

## Status of the rest of the item

Everything else in `## Change` is implemented and gated green in that
worktree/branch (`bin/cosmic --make ci` → `ci: PASS (5 stages)`),
committed locally as `5979c511` on branch `3I1JDVLm`, but NOT pushed
and no PR opened, per the builder brief's stop-don't-improvise
instruction. The worktree at `/home/user/wave9/kxK7_MuJk` has been
left in place (not cleaned up) so that commit is available to whoever
resumes this item once bullet 4 is resolved.
