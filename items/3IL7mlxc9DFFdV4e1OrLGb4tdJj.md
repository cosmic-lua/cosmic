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
