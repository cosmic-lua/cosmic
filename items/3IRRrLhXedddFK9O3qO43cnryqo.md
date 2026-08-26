A base-branch update between accept and merge leaves a permanent
head-mismatch warning on land, and gitboard offers no way to
re-affirm the verdict for a delta that is mechanically a base-merge.
Observed 2026-08-26 on board item 3IQQf63I (PR #1394): the accept was
recorded at head `aacd57d2`; the merge was refused ("Required status
check build is expected") because main had moved under it; the branch
update added one merge-of-main commit, making head `3f81dd31`; after
the re-run went green the merge succeeded and `gitboard land` printed
`WARNING PR #1394 merged at 3f81dd3 but the accept judged aacd57d`.
The reviewer did verify by hand that the only delta was the base merge
(same additions/deletions, one extra commit whose diff against the new
base was unchanged), but that verification lives nowhere — the log
keeps the warning forever, and a later reader cannot tell a benign
base-merge from a post-accept rework that dodged review. Candidate
shapes: `verdict ID accept --pr N --head NEW` re-recording on the same
item when the old head is an ancestor and the tree diff against the
merge-base is byte-identical (the tool can check both); or `land`
itself performing that ancestry+diff check and printing "head moved by
base merge only" instead of the warning, reserving the warning for a
delta that contains non-merge commits.
