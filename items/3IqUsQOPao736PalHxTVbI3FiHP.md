## Evidence

Both `/work 9 --routine` orchestrators on 2026-09-04 ran a bare
`gitboard take ID`, which succeeded and bound the claim to the
orchestrator's own derived identity; the NEXT bare take refused with
`REFUSED: <uuid> already holds <id> — one claim per worker; drop it or
finish it first` (`_work/gitgate.tl:268`). Each then dropped and
re-took under a minted name: 4 extra verbs and two bogus claim/drop
entries in the board log per session. `gitboard help take` documents
`--session` as "Omit to derive it from the environment", and `help
orchestrate` says to mint a name per agent, but nothing says the
derived identity is a one-claim identity that an orchestrator must
never use for a pull or a review it will hand to an agent.

## Change

`_work/gitverbs.tl`, `take`'s `--session` option text: "the claiming
session; an orchestrator claiming for an agent always passes the name
it minted for that agent — omitted, the claim binds to THIS session's
one-claim identity". `_work/gitgate.tl:268`, the one-claim refusal:
append "— an orchestrator claims under `--session <minted name>`, one
per agent". `_work/doctrine.tl`, orchestrate's "Claim first, then
spawn" bullet: add the same sentence in the doctrine's voice.

`_work/gitgate_test.tl` and `_work/doctrine_test.tl`: pin both
sentences.

## Non-goals

No refusal of a bare take: a solo session pulling for itself is the
bare take's purpose.
