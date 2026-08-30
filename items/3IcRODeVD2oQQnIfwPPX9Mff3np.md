## Evidence

Found while triaging pull candidates 2026-08-30: `gitboard tree` and
`gitboard check` are cited in Acceptance/Enablement prose across at
least 30 item spec sidecars (17 still open, the rest already
`completed`), but neither exists as a `gitboard` verb:

```
$ o/bin/gitboard tree
unknown command 'tree': init, new, attach, compare, block, unblock, set,
spec, next, take, drop, verdict, done, show, sync (try --help)

$ o/bin/gitboard check
unknown command 'check': init, new, attach, compare, block, unblock, set,
spec, next, take, drop, verdict, done, show, sync (try --help)
```

Both are missing from the same `help` output too. The 17 currently-open
items still citing one or the other (found via
`grep -rl 'gitboard tree\b\|gitboard check\b' items/*.md` in the board
worktree, cross-checked against each item's `resolution` field):

```
3I5b4zi2SoomJ2E8Io05V0UCsqh   3IBFBWtcYeFo8Io3zITgKs0PfCy
3IL7mlxc9DFFdV4e1OrLGb4tdJj   3IQtgMjycyFrxa8xT2ZqwOHfdJl
3IR2PzsvUtx656TYbEptg7lmgDq   3IR2RMdNvdkoLQaNLhJb8CTqoDU
3IR2RYCJWgbBWzTBuzi95knULxq   3IR2RpK9Fvcw40NFlHfjyorwi5s
3IR2SFOqEXQ4luAS8FK0Km2AzEa   3IR2SQaCFZX6EZSVQI7aPvfGezb
3IR2SiiKMbGYSBHfuync4bC2Mi4   3IR2SvRbCemV8SZev557Gbq90xl
3IR2TE1OmxyrM9TfqkUYAQqFsja   3IR2TQdUPE14YWg2XOZBljh1iL7
3IR2TpB3LzucKMLBikykPjHSBKS   3IR2U42tzzZaV7nMWHqYloPx1CX
3ISCk9jyvgHUio3gPwQuZkSURUB   3IVDKtsgy6vtPvhtQoCRGvX4ZXE
```

(`3IVHIoAxfoGDPf7ouDIJtvGoxgI` also matched the grep but is a false
positive — its title says "gitboard check: the ready bar accepts...",
using "check" as a plain English word about the ready bar, not the CLI
verb.)

One concrete example, `3ISCk9jyvgHUio3gPwQuZkSURUB`'s `## Acceptance`:
`` "$BOARD"/o/bin/gitboard tree 3IOCgCWG lists one port child..." `` and
`` "$BOARD"/o/bin/gitboard check <id> passes for every port child
filed. `` — neither command exists, so that item's ready-bar cannot
actually be satisfied as written.

This is likely a rename-era casualty: the recently-landed board commit
"gitboard: two derived states, two gates, one bound (#1500)" collapsed
the old stage-column model (which `tree`/`check` presumably served) into
`next`/`show`, but the specs that predate it were never swept for the
old verb names.

## Non-goals

This item does not itself decide the fix — whether the missing
functionality (listing an item's children with their claim/PR/verdict
state; batch-validating a set of items against the ready bar) should be
rebuilt as new verbs, or whether the 17 open specs should instead be
edited to use `show`/`next`/a loop over `show` per item. That's a
design call for whoever picks this up.
