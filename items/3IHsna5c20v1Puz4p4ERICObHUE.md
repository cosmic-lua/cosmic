`_work/gitverbs.tl` cannot hold the three `cmd_move` slices now in
flight, and each of them passed its own gate.

Measured 2026-08-22 against board head `6de0d2cb`, where
`wc -l < _work/gitverbs.tl` is 464:

| PR | item | adds to gitverbs.tl | file after, alone |
|----|------|--------------------|-------------------|
| #1319 | 3ICDNqdv (land gate) | +19 | 483 |
| #1320 | 3IE6ttNh (builders) | +23 | 487 |
| #1321 | 3ICDOGbm (builder distance) | +33 | 497 |

Each is under the 500-line cap on its own branch and each ran
`--make ci` to `ci: PASS`. Landed together they are 464 + 75 = **539**,
so whichever lands third fails `cosmic --check lint` on a diff that
did not change a line the second one touched. All three were specced
in the same refinement pass, and all three `Change` sections quoted
that same 464 as headroom — because each measured the file as it
stood, which is what the ready bar asks for, and no one of them was
wrong.

The generalisable part: **the ready bar's measured-headroom rule is
per-slice, and a per-slice measurement cannot see concurrent slices.**
The cap is a shared resource; a spec that budgets it reads a number
that is only true while nothing else is in flight. This is the same
class as 3IHFPLpb (a `_fuzz` test file measured at 471 by a spec whose
own change would have taken it past 500), but the mechanism is
different: there the spec forgot to budget its own addition, here every
spec budgeted correctly against a file that three specs were each
budgeting at once.

Worth weighing, not a decision:

- split `_work/gitverbs.tl` first, as its own slice, so the three have
  somewhere to land. The natural seam is `cmd_move`, which now carries
  four gates and a same-phase write and is the only function all three
  touch.
- have the ready bar's headroom claim be a claim about the file
  *including other open slices* — which needs the board to know which
  files an item's `Change` names, and today it does not.
- a lint that fails a file within N lines of the cap, so headroom is
  gone before it is gone rather than at the moment a third diff lands.

## Where the evidence is

whilp/cosmic#1319, #1320, #1321, and the `Change` section of each of
`3ICDNqdv`, `3IE6ttNh`, `3ICDOGbm`.

## Triaged 2026-08-23 — the instance closed, the rule did not

Re-measured at triage: `wc -l < _work/gitverbs.tl` prints **255**, and all
three items are ended (`gitboard show` reports `3ICDNqdv`, `3IE6ttNh` and
`3ICDOGbm` each `completed`, carrying PRs #1319, #1320 and #1321). The first
option above — split `gitverbs.tl` so the three have somewhere to land — is
what happened, so the concrete 539-line collision no longer exists and the
table above is history, not a live problem.

What survives is the generalisable half, unchanged and unaddressed: **the ready
bar asks each slice to measure headroom, and a per-slice measurement cannot see
concurrent slices.** The cap is a shared resource that every spec budgets
privately. Nothing on the board or in `decompose.md` closes that today, and the
next contended file will reproduce it exactly.

Attached under G8 (the flow system) rather than under the fuzz container that
holds its sibling `3IHFPLpb`: that item is parented by file locality
(`_fuzz/driver_test.tl`), while the defect here is a property of the ready bar
itself. The two are the same family and differ in mechanism — `3IHFPLpb` is a
spec that failed to include its OWN addition, this is three specs each measuring
correctly and colliding — so whichever is refined first should read the other,
and a countermeasure that fixes only one of the two mechanisms has not fixed the
class.
