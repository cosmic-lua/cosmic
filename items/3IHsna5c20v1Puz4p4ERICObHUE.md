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
