Item 3HyEla9L's spec (the deep-fuzz workflow, landed as PR #1262) predicts the
tool's forced-failure verdict text as `test: FAIL (1 test)` in its Acceptance
section. The actual, real output of `bin/cosmic --make test <one file>` on a
single failing check is `test: FAIL (1 of 1 file)` — confirmed by running it
during implementation. The implementer judged the substance (a FAIL verdict
plus the seed/iteration/input message) as satisfying the intent and proceeded
rather than bouncing, but the literal predicted string does not match what
the CLI actually prints.

This is a small, narrow drift between spec prose and real CLI wording, but
it is exactly the kind of thing a less careful implementer could get stuck
on (does a mismatched literal in a facts/acceptance block mean the spec is
wrong, or the code regressed?). Worth a planner either fixing this one
item's already-landed spec text for the historical record, or — more
usefully — checking whether other specs' Acceptance sections quote `test:
FAIL (...)` verdict strings that might carry the same stale `(N test)` vs.
`(N of M file)` wording.
