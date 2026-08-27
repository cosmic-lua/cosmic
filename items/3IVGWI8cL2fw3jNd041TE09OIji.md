`_work/gitverbs_test.tl` is 10 lines under the hard 500-line cap on the `board`
branch: `wc -l < _work/gitverbs_test.tl` is 490 after PR #1461 added
`test_spec_refuses_a_write_with_no_base` and `test_spec_refuses_a_stale_base`
to it (441 before). It is the file every verb refusal in `_work/gitverbs.tl`
is pinned in — 21 test functions across `move`, `done`, `spec` and the ready
bar — so it is also the file the next verb change wants to add to, and the
next addition of any size fails `cosmic --check lint` rather than the test it
was written for. The two adjacent seams a split could follow are already
visible in the file's own ordering: the phase crossings (`move`, `done`, the
WIP and force refusals) and the sidecar verbs (`spec`, the ready bar, the
evidence handover). `_work/gitverbs.tl` itself sits at 373, so the source side
has room; only the test side is at the wall.
