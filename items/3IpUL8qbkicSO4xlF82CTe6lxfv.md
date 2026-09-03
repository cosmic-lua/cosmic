## Evidence

`gitboard next` on 2026-09-03 offered «1j6D_hfCe» as the head pull. Its
Change requires a measurement on a calendar day different from the
four its Evidence records (all 2026-09-03), so any session that day
either bounces or violates the spec; the orchestrator skipped it by
hand. The readiness fact was real and checkable (`date -u +%F` against
the recorded session dates) but lived only in the reader's inference:
`help bar` asks for measured tree-facts and behavioural claims with
their commands, and `help build` step 2 has the puller re-run the
spec's measured commands before building, but neither names the case
where the fact deciding whether to START is outside the tree — a
calendar day, a release having shipped, a lane green, a pin bumped.

## Change

`_work/doctrine.tl`, the bar topic, after "Measured, not inferred":
one paragraph — a Change whose earliest valid start depends on a fact
outside the tree states that fact as a command and the output that
means ready, in prose at the top of `## Change` ("Ready when: ...");
the puller runs it before anything else and, when it says not ready,
drops the claim bare (the item is fine as written, re-offered as-is)
rather than bouncing through a question. No field, no date, no verb:
the criterion is whatever the command evaluates, and it ages with the
spec.

`help build` step 2 gains the mirror sentence: "a `Ready when` command
runs first; not ready is a bare drop, not a bounce".

`_work/doctrine_test.tl`: pin both sentences.

## Non-goals

No item field, no `next`/`take` change: the tool never evaluates the
criterion, the puller does.
