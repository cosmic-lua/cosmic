Evidence (re-review of PR #1555, 2026-08-30, verified live): the
PR-less `done` gate keys on the append-only `it.builders`, and the
`reject` verdict clears `claim`/`pr`/`verdict` but never `builders` —
so reject-then-done-without-force is correctly REFUSED today. But no
test pins that interaction: of the three "verdict/claim churn while
builders survives" paths, drop-then-done and accept-then-done are
tested and reject-then-done is not, so a future edit to reject's
field-clearing or the gate's predicate could silently reopen it. The
change: one test in `_work/gitverbs_test.tl` beside the drop-then-done
one — take, verdict reject (distanced session), then done with no
force → refused; with --force --why → completes. Mutation-verify
against a claim-based gate.
