## Evidence

Observed 2026-08-24 as the bounce of `3IKuRFN5` (zipos freelist
research), which reached `ready`, was claimed, and was returned to
`plan` at claim time without a line of work done.

That spec meets the ready bar in every respect the bar checks: its
`Change` is three numbered questions, every constraint is quoted by
`file:line`, every Acceptance command states what it returns today,
and its `## Enablement` section even anticipates the failure — "if the
clone cannot be reached at all (no egress, or the proxy refuses it),
that is a bounce". What no gate checked is the thing that actually
stopped it: the spec's central command is

```
git clone --filter=blob:none --no-checkout \
  https://github.com/jart/cosmopolitan /tmp/upstream-cosmo
```

and a scheduled session's GitHub access is granted per repository. This
session's grant was `whilp/cosmic` + `whilp/cosmopolitan`;
`jart/cosmopolitan` was not in it, so the source the slice exists to
read was out of reach before the claim was made.

The cost is one wasted pull and one bounce — small here, and structural
rather than one-off: the ready bar verifies that a session can implement
from the spec ALONE, and says nothing about whether a session can REACH
the sources the spec names. Any slice whose evidence lives outside the
grant has the same hole, and the failure always surfaces at claim time,
after the item has consumed a `ready` slot and a pull.

Today's spec grammar has no place to state it:

```
$ grep -rn -i 'precondition\|access\|grant' _work/spec.tl
                                    # nothing
```

## Change

Give the ready bar a way to see an out-of-grant source, so `check`
catches it instead of a claim.

Two halves, and the refinement decides how much of each:

- **the grammar** — a spec that names a repository other than the
  item's own `repo` field (or `whilp/cosmic`) states the read access it
  needs, in a named place `_work/spec.tl` can find. A URL or `owner/repo`
  reference is a cheap syntactic signal.
- **the gate** — `gitboard check` refuses `ready` for an item whose spec
  reaches a repository it has not declared, the same way it refuses one
  with no position in the priority order. The refusal names the
  repository, so the session either declares it or re-specifies the
  slice around a source it can reach.

Core tier by `enable.md`'s ordering, and it belongs there rather than in
prose: whether a spec names an out-of-grant repository is exactly the
kind of thing a machine can check, and a rule written into `decompose.md`
would reach only the sessions that read it.

## Non-goals

- **Do not try to verify the grant itself.** The board has no way to
  know what a future session's access will be, and guessing would make
  the check both wrong and annoying. The gate checks that the
  requirement is DECLARED, not that it is satisfied.
- **Do not widen it into a general external-dependency checker.** The
  subject is repository read access, which is granted per repository and
  is what bounced `3IKuRFN5`.

## Acceptance

To be written at refinement, against `_work/spec.tl` and
`_work/gitgate.tl`, with `3IKuRFN5`'s spec as the fixture the new check
must refuse.

## Second occurrence, 2026-08-24 — it strands the REVIEW too

Observed while reviewing `3IKuRFN5` from session
`claude-sched-2026-08-24T0238`, whose grant is the same
`whilp/cosmic` + `whilp/cosmopolitan` that produced the bounce above.

The bounce framed this as a claim-time hole: the bar checks that a
session can IMPLEMENT from the spec alone and not that it can REACH
the sources the spec names. The review shows the hole is one step
wider. `3IKuRFN5`'s `## Acceptance` opens with

```
git clone --filter=blob:none --no-checkout https://github.com/jart/cosmopolitan /tmp/upstream-cosmo
git -C /tmp/upstream-cosmo log --oneline -- libc/zipos/ libc/runtime/zipos-open.c libc/runtime/zipos-close.c
```

and `review.md` requires the reviewer to demand that evidence — for a
research slice, to re-run the acceptance checks itself. A reviewer
under the grant cannot, so the accept rested on the in-grant half plus
the finding's own conservatism, and half the deliverable went onto the
board attested by one unattended session and nobody else.

So the cost is not one wasted pull. An out-of-grant source strands an
item **twice**: once at the claim, once at the verdict, and the second
one leaves an unverifiable claim permanently on the board rather than
merely burning a `ready` slot.

What this adds to `## Change`, and it is a scope widening, not a
detail: whatever declares the required read access must be checked
against the REVIEWING session too, not only the claiming one — an
item whose Acceptance a reviewer cannot re-run is not reviewable, and
`check`'s refusal should say so at the same moment it says the claim
is impossible. A weaker but cheap alternative the refinement should
weigh: require any such spec to carry the out-of-grant evidence
verbatim in-item (the commits, messages and diffs quoted), so the
reviewer's job degrades from re-running to reading. `3IKuRFN5` in fact
did that, which is the only reason its accept was defensible.
