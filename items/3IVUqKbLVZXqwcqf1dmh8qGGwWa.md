## Evidence

Found 2026-08-27 during 3IVKVXoO's review (PR 1466), by mutation: the
reviewer neutralised the `vacated` read in `cmd_new` and the whole
suite stayed green at that head and at its base.

`cmd_new`'s up-front WIP gate cannot refuse anything: a filed child
always gets `phase = "backlog"` (`_work/gitgraph.tl:42`), and
`flow.LIMITS` deliberately has no `backlog` entry, so
`wip_refusal(board, nil, "backlog", vacated)` is nil for every input —
the gate, the `vacated` slot it reads from the parent-to-be, and the
`--force` escape documented around it are dead code. The same fact made
the deleted post-race revalidate dead for `cmd_new` too (its
`limit ~= nil` guard never armed), which 3ICDOfPj's fix could not have
known when it taught the closure the vacated credit. The cleanup is to
delete the dead gate and its `vacated` plumbing from `cmd_new` (the
credit stays real in `cmd_move`, where a de-phasing decomposition does
arrive in a bounded column), and to drop or repoint
`gitgate_test.tl`'s vacated assertion, which today exercises
`wip_refusal` directly rather than any live caller.
