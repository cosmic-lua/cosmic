Mechanically delete the test self-call lines across the tree —
2,786 calls in 260 files measured at capture (grep -h
"^local function test_" over git ls-files '*_test.tl') — using the
discovery walk to find each definition's end and the call after it,
landing in reviewable per-directory batches, each green under
`--make ci`. No semantic edits ride along; a file whose calls are
load-bearing beyond invocation (if any) is left legacy and noted.
The tree ends all-runner. Context: docs/design/test-runner.md
(branch claude/cosmic-test-runner-rgb819).
