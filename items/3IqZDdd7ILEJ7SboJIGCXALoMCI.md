## Evidence

`c5wU_p1n9`'s research handover was rejected (session
`review-c5wU_p1n9-3`, verdict `reject`) because its `## Decision`
("does NOT reproduce, close with no code change, mark `pmIX_ommp`/
`3IonN6Kw`'s flag as noise") was written 2026-09-03T16:57:58Z, BEFORE
the item was blocked on `3IpIfJ5GpiJw2CrhUBB1j6DhfCe`, and was never
reworked after that blocker cleared. `3IpIfJ5G` — the item blocked on
for exactly this same-day-split adjudication — was itself accepted
with the OPPOSITE finding: its one genuinely day-separated,
hash-verified session (2026-09-04) found 11/12 pairs (92%) "new
slower", pooled mean +4.15%, outside a same-binary control band of
≤1%. The reviewer's own fresh, third independent build (bit-identical
hashes to both prior sessions) re-ran 6 interleaved pairs and got 5/6
"after slower", ~+4.4% mean excluding one outlier pair — consistent
with `3IpIfJ5G`'s regression finding, not with `c5wU_p1n9`'s stale
"net zero" decision.

Full reviewer report (session `review-c5wU_p1n9-3`, this pass,
2026-09-04) is the primary source; see also `3IpIfJ5G`'s own closing
text: "At least one more session, on a calendar day distinct from
both 2026-09-03 and 2026-09-04, is still needed before c5wU_p1n9 ...
can be resolved per this item's own decision tree — but that next
session should note this session's corrected direction (regression)
going in, not the superseded 'no stable direction' first reading."

## Question

`c5wU_p1n9` cannot self-resolve today (2026-09-04 is already used by
both `3IpIfJ5G` and this item's own earlier rounds) — it needs either:

(a) one more measurement session, on a calendar day distinct from
    both 2026-09-03 and 2026-09-04, carrying forward "regression" as
    the working hypothesis per `3IpIfJ5G`'s own instruction (not the
    superseded "no stable direction" reading `c5wU_p1n9`'s current
    spec still asserts); or

(b) a decision by the goal owner to short-circuit further
    measurement rounds entirely and go straight to evaluating the
    low-risk static-proof fix at the one narrowing site in
    `cosmic/re.tl`'s `match()` (per `c5wU_p1n9`'s own `## Change`
    step 2's first option: "proving the invariant statically so no
    runtime check is needed at all") regardless of the exact
    magnitude, since three independent sessions now agree on
    direction even if the day-separation bar isn't yet fully met.

This item exists to hold that choice open until answered; `c5wU_p1n9`
is blocked on it in the meantime.

## Non-goals

Not re-running the measurement a fourth time itself — that is either
this item's own eventual `## Change` (if (a) is chosen) or moot (if
(b) is chosen). Not deciding D23/D30's assert-justification policy —
same wall `c5wU_p1n9` already carries.
