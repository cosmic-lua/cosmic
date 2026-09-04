## Evidence

With several orchestrators on one board, a `done ID` often arrives
after another session recorded the same completion. Today that path
returns `nothing to record: done <id> completed (from accepted) leaves
the board unchanged` (`_work/store.tl:309`) with exit status 1, the
same status as a real refusal; the 2026-09-04 routine logs record two
such calls, each followed by a `sync` and a `show` to learn the item
was in fact already closed. The state the caller asked for is the
state the board holds; the verb did its job.

## Change

`_work/store.tl` (the commit path that produces "nothing to record")
returns a distinct outcome — `true, "nothing to record: ..."` or a
third-slot-free `NOOP` sentinel the verb layer maps — so `done`,
`take --pr N` with the same PR already recorded, `verdict` with the
same verdict on the same head, `set` with the same value, `block` and
`compare` with an edge already present all print the existing
"nothing to record" line and exit 0. A mutation refused for any other
reason keeps exit 1. `gitboard help system` gains one sentence:
"a mutation the board already holds is a no-op that succeeds".

`_work/store_test.tl` (and one verb test per listed verb): the
already-recorded case asserts status 0 and the line.

## Non-goals

No change to what is written: a no-op still commits nothing and
pushes nothing.
