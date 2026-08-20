## Evidence

2026-08-20 machinery audit of the board branch (at 5577fd73; still
true after #1298/#1299). `_work/gitland.tl:56-64` fetches the PR —
`p.head_sha` in hand — and the item's `verdict_head` is loaded, but
no comparison is made, and `gh.merge` (_work/gh.tl:138) sends
`{merge_method = "squash"}` WITHOUT GitHub's `sha` guard parameter,
which exists for exactly this. Scenario: reviewer accepts at head H;
builder pushes more commits; any session lands — the PUT merges the
new head unreviewed. The already-merged path (gitland.tl:61-63) has
the same hole: a PR "merged by any other route" ends the item
completed regardless of what merged relative to the accept. Two
adjacent gaps in the same verb: no branch for a PR closed UNMERGED
(`p.state == "closed" and not p.merged` falls through to a PUT that
405s, rendered as "re-run land once the cause clears" — a cause that
never clears, and `next` names finish on it forever), and the status
classifier (#1265, _work/gh.tl:160-169) treats only 403 as the
permission wall while GitHub reports most branch-protection refusals
and closed PRs as 405 and base-modified races as 409 — both land in
the generic re-run branch. Related standing capture: 3I8lUm1r (land
cannot merge protected main with its own token; every recent PR shows
merged_by whilp).
