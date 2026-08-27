Container 3IOCdooE ("migrate the tree: delete the test self-call lines,
directory by directory") carries TWO decompositions of the same work,
opened seven minutes apart on 2026-08-27, and they cover overlapping
directories:

- the 3-batch series, opened 04:50Z: 3IU5JFiR (`cosmic/**`), 3IU5JUI8
  (`_make`, `_cli`, `_tool`, `_build`, `_types`), 3IU5Jn4h (the
  remainder plus the AGENTS.md prose flip).
- the 7-batch series, opened 04:57Z: 3IU6AZEx (`_build`, `_docs`,
  `_types`, `3p`, `_fuzz`, `_eval`, `_perf`, `_tool`), 3IU6AgNN
  (`_cli`, `_make`), 3IU6AsZC / 3IU6B7LD / 3IU6BPFg / 3IU6BiCH /
  3IU6BjUI (`cosmic/**`, split five ways).

Every directory in the tree is claimed by one item in each series, so
whichever pair lands first makes the other's diff empty and its
Acceptance unrunnable as written.

They also disagree structurally. The 7-batch items each carry a real
blocker edge on 3IU62YqO (the pin bump), with the reason recorded on
the edge: `_build/coldbuild_test.tl` type-checks the tree with the
PINNED release's checker, which predates D29's compile seam (#1446,
`7b9f0749`), so any runner-mode test file fails it with an
uncalled-local warning until the pin moves. The 3-batch items stated
the identical gate as prose in their `## Enablement` only, so both
read as unblocked and ready-bar-clean to `next` until this session
added the missing edges (`block 3IU5JFiR 3IU62YqO`,
`block 3IU5JUI8 3IU62YqO`).

Resolution is a choice between the two, not a merge: end one series as
not planned and keep the other. The 7-batch series is the better
candidate on the evidence — finer-grained, file-disjoint per batch,
and it already carries the dependency structurally rather than in
prose — but that is a judgment for whoever owns the container, and
either way the surviving series should be re-measured against main
before any of it is pulled.
