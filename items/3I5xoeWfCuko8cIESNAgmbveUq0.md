Board item 3I1IfJ22 ("G2: sandbox enforcement reaches the kernel's ceiling and
says what it enforced")'s "Where we stand" section lists "defect 2" as open:
"`REFER` is handled but never granted... cross-directory rename/link is denied
even between two directories inside the same `rw` grant."

This is stale. `cosmic/sandbox/landlock.tl`'s `WRITE` mask already ORs in
`REFER` (with a doc comment explaining the cross-directory-rename motivation),
`abi_mask` strips it below ABI 2, and `cosmic/sandbox/landlock_test.tl` already
has `test_rw_grant_allows_rename_within_its_tree` plus
`test_access_mask_composition` proving it — landed via commit `854b059f`
(2026-08-15), predating the epic's current text.

The epic's spec should be corrected to mark defect 2 done and drop it from the
Phase-1 decomposition sketch, so a future planner refining this epic doesn't
re-derive or re-file it. Low urgency — a one-paragraph edit to the sidecar,
found while refining board item 3I5xg5TL (the probe-consolidation slice).
