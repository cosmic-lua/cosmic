`gitboard new --repo OWNER/NAME` is the only way an item's `repo` field
is ever set, and it refuses a parentless item — "claim/pr/verdict/repo
belong to worked items, not roots". So an item whose cross-repo
destination becomes known after it was opened has no verb that can
record it: `attach`, `move` and `spec` all leave the field alone.

## Three occurrences, at both ends of an item's life

`3I7LDODd` on 2026-08-21: its spec said the PR lands in
whilp/cosmopolitan and told the session to "set it on this item when it
lands", but `move ID check --pr N` reads the PR against the board's
origin and refused with
`cannot read PR #267: GET /repos/whilp/cosmic/pulls/267: HTTP 404`.

`3I7LEsGv` the same day, handing wave 2 over:

```
gitboard-move: REFUSED: cannot read PR #268:
GET /repos/whilp/cosmic/pulls/268: HTTP 404: Not Found; --force to hand it over anyway
```

Both were worked around the skill's once-only way — hand-edit
`items/<id>.tl` to add `["repo"] = "whilp/cosmopolitan"` and commit
(board commit "repo 3I7LEsGv whilp/cosmopolitan") — after which the
move succeeded. The file format held; the workaround is exactly what
the hard rule says to file rather than repeat.

2026-08-23, the other end: the first board-backed perf research pass
(optimize skill) filed four C-layer hypothesis captures and tried
`new --spec-file F --repo whilp/cosmopolitan`; refused as above, so
the landing repo lives only in each spec's prose (items 3IK8E4XF,
3IK8GFHj, 3IK8GTDo, 3IK8Gkq1) and will need this fix — or the hand
edit — when each is worked.

## Why it matters

Every cross-repo item is filed this way, so the workaround is not a
one-off: it is the only path for any item whose repo is decided after
it is opened, which is the normal case when a capture is triaged into a
plan. Each use is a hand-edited commit bypassing the tool's validation.

## Fix shape (recorded 2026-08-23)

A dedicated `gitboard repo ID OWNER/NAME` verb: settable on any
workable item in any phase (triage-time, plan-time, or right before
the check handover), refused on roots and containers — the existing
principle holds, and it should, because a capture's landing repo is a
refinement decision (the same research pass split one hypothesis into
a cosmic half and a cosmopolitan half at analysis time, and
finding.md's "wrapper is already thin" rule re-targets an item across
layers mid-investigation). A latent repo field on roots would be
stale data nothing validates. Two companions: `move`'s existing
404 refusal names the verb as its remedy, and clearing back to the
board's origin is expressible (the block/unblock shape). `attach
--repo` sugar is optional once the verb exists; a generic
`set ID field=value` is rejected — each mutation verb's refusal
encodes an invariant, and repo deserves the same typed treatment as
block and compare.
