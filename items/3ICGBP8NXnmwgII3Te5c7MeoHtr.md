## Evidence

2026-08-20, hit live. `gitboard status` ended with:

    gitboard-status: WIP: plan 12/12 at limit — arrivals refused; triage 9/8 over limit

`next --session dji1my` then answered `triage 3I7LNOT7 … — 9 item(s)
awaiting triage, over the bound of 8 — draining outranks refining`,
and the triage act is `attach`. Attaching into a phase the verdict
line had just called closed succeeded:

    gitboard-attach: 3I7LNOT7 now under 3I1IfJ22 — workable, in plan

That is CORRECT behaviour and deliberate — `_work/gitverbs.tl`'s
`cmd_attach` says so at the point it sets the phase:

    -- Adoption makes a leaf workable: it enters plan, ungated —
    -- triage is a decision already made, the same admission the
    -- label board gave findings.

It has to be ungated, or an over-bound triage queue could never drain
while `plan` sits at its limit — a deadlock between two rules the
ordering deliberately resolves in triage's favour ("draining an
over-bound triage queue jumps ahead of refinement").

## The gap: the verdict line claims otherwise

`status`'s rendered violation reads "arrivals refused" unconditionally
whenever a phase is at limit, but `flow.admits_over_limit` is not the
only admission path — adoption into `plan` bypasses the arrival check
entirely, and it is exactly the path a session is sent down when
triage is over its bound. So the one line a session is told to read
instead of the tool's exit status asserts a rule the tool does not
enforce, in the specific situation the ordering steers into.

The concrete risk is a session reading "plan 12/12 at limit — arrivals
refused", concluding triage is blocked until plan drains, and skipping
the drain — inverting the right-to-left priority. Triage stood at 25/8
later the same day, so the over-bound case is live, not theoretical.

## Fix shapes (not chosen here)

- Narrow the wording to what is actually refused: "arrivals refused
  (adoption from triage still admitted)", or simply "at limit" with
  the refusal claim dropped.
- Or render the exemption where it is decided rather than in prose:
  have `status` name the admitted classes (`return`, `accept`,
  `adoption`) once, next to the limits, so the vocabulary matches
  `flow.admits_over_limit` plus `cmd_attach`'s carve-out.

Cheap either way — this is a rendered-string honesty fix, not a policy
change. The policy is right; only the sentence describing it is wrong.
