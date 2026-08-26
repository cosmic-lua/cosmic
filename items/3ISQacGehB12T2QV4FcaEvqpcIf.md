Every landing during parallel hours pays a base-update CI cycle: main
moves while a PR sits accepted, the merge is refused ("Required
status check 'build' is expected"), the branch updates, the full
suite re-runs (~4-5 minutes), and only then does the merge go
through. Measured 2026-08-26 on PR #1394: accepted at head aacd57d2,
merge refused, branch updated to 3f81dd31, ~4 minutes of re-run,
merged — and the same shape recurred on most landings today because
six PRs merged into main within hours of each other, so a moving
base was the norm, not the exception. At K landings/hour the tax is
K-1 full CI cycles of pure serialization. GitHub's merge queue is
the purpose-built fix — accepted PRs enter a queue that batches and
tests the merge result once — but it changes the landing contract
the board's land verb and the drive-to-green rules assume (merge
happens at accept-time by the lander), so adopting it is a decision,
not a toggle: land would enqueue rather than merge, the verdict-head
question (3IRRrLhX) changes shape, and the required-check set moves
to the queue's context. The item is the evaluation: measure today's
re-run tax from CI logs, state the land-verb changes a queue needs,
and decide adopt or reject with the tradeoff recorded.
