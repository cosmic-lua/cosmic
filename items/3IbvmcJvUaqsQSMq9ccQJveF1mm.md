Evidence (operator screenshot, 2026-08-29, first merge-queue-era PR):
the PR checks panel shows 10 successful checks for 5 jobs — each pr.yml
lane reports twice, once as its Actions check run (`pr / ci
(pull_request)`, `pr / build`, ...) and once as the `gate/<lane>`
commit status the gate-status composite action posts from inside the
same run. The compute runs once; the reporting is doubled by design
(D38: stable `gate/*` context names resolvable on every trigger type,
intended as the queue ruleset's required contexts). But the panel
badges `pr / build (pull_request)` as Required — the enabled ruleset
requires the Actions check-run name, not the `gate/*` contexts D38
planned (the handoff had named gate/ci, gate/build, gate/repro,
gate/smoke-*). Reconcile the two: either the operator points the
ruleset's required checks at the `gate/*` contexts per D38 (and the
Actions names stop being required), or the `gate/*` mirroring is
retired and D38 is amended to record that the queue requires the
check-run names directly (merge_group runs produce the same `pr / *`
check names, so requiring them works across triggers). Decide first
which names the ruleset should require — that decision is the
operator's/goal owner's; the buildable half is the follow-through
(gate-status removal or D38 amendment). Read the actual ruleset
configuration before building; the screenshot is one PR's view.
