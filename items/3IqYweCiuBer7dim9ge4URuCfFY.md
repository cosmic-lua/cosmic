## Evidence

Builder session for `xK61_V4t0` (`gitboard: refuse a mint that
duplicates an open item...`) found, after being handed a worktree on
a fresh branch off `origin/main`: the bulk of the item's `## Change`
(`_work/dedup.tl`, `_work/gitgraph.tl`, `_work/dedup_test.tl`,
`_work/gitgraph_test.tl`, `gitboard help new`) exists only on the
orphan `board` branch — `git show origin/board:_work/gitgraph.tl`
succeeds, `git show main:_work/gitgraph.tl` fails ("path does not
exist"). The item's base has now been repaired to `board` (this
session's `gitboard set xK61_V4t0 --base board`), matching its
sibling board-tooling items (`RxN2_253n`, `FacE_b8sh`, `Elus_cLzz`,
`rNh1_b1Se`, all `base: board`).

But the item's `## Change` ALSO names a one-sentence addition to
`skills/work/SKILL.md`'s "intake paragraph" — and `skills/work/` does
not exist on `board` at all (`git ls-tree origin/board` carries only
`_work/`, `items/`, `bin/`, `cmd/`; no `cosmic/`, `skills/`, `docs/`).
`skills/work/SKILL.md` only exists on `main`. Additionally, the
builder read the current `main` copy of that file in full (98 lines)
and found no "intake paragraph" to extend — the file today is only
about the `/work N` orchestrator loop and explicitly disclaims
restating the tool's doctrine.

So as written, `xK61_V4t0`'s `## Change` spans two disjoint branch
histories in one repo (`board` for the `_work/*.tl` code and tests,
`main` for a `SKILL.md` sentence that doesn't have anywhere to go
today) — a genuine split-scope spec, not something one item/one
PR/one `base` can build as one diff.

## Question

Either: (a) split `xK61_V4t0` into two items — one scoped to the
`_work/**` dedup check (base `board`, as now set), one scoped to
adding an intake-check mention somewhere in `skills/work/SKILL.md` on
`main` (needing a refiner to say where, since no "intake paragraph"
exists to extend); or (b) drop the `SKILL.md` sub-bullet from
`xK61_V4t0` entirely, leaving the doc mention as a `main`-side
follow-up if wanted at all, since `help new`'s own doc (which DOES
live on `board`, `gitboard help new`) already covers the same ground
for anyone learning the check from the tool itself.

This is a refiner's call, not a rebuild-and-hope: the previous
builder attempt on `xK61_V4t0` already spent ~15 tool calls
discovering the branch mismatch before stopping correctly rather than
guessing.
