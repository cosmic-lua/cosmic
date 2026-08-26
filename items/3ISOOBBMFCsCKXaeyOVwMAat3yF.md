The verdict verb's vocabulary is guessable-wrong in the costly
direction, and its unknown-kind error does not teach. Observed
2026-08-26 on item 3IOCco6e: a reviewer intending the middle verdict
tried `request-changes` (hyphenated, the GitHub spelling) and got
"unknown verdict: request-changes" with no list of valid kinds; tried
`rework` (the word review.md's prose uses for the state) — unknown
again; fell through to `reject`, which parsed, and de-committed the
item to backlog — a much harsher move than intended (request changes
-> do keeps the builder's claim; reject -> backlog spends the
commitment). The board then needed a hand-repair move to restore the
rework state. The actual kind is "request changes" WITH A SPACE,
discoverable only by reading _work/gitverdict.tl's VERDICT_MOVES
table. Three one-line fixes, any subset: the unknown-kind error
enumerates the valid kinds; common aliases (request-changes, rework)
map to "request changes"; and given reject's stronger consequence, a
reject could ask for confirmation the way --force asks --why. The
verdicts are the system's highest-consequence single keystrokes;
they should be the hardest to get wrong, not the easiest.
