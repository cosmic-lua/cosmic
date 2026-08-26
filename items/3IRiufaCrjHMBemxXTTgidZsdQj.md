`land`/`done` re-phase a finished container to `backlog`, but the line
they print says `plan`, so a session that reads the verdict goes
looking for the container in a queue it is not in.

Observed 2026-08-26 landing `3IRcbbAV`, the last open child of
`3IOFN9bn`:

```text
gitboard-land: PR #1400 was already merged
gitboard-done: 3IRcbbAV completed (land) — 3IRcbbAV was its last open
  child, so 3IOFN9bn returns to plan
```

`gitboard show 3IOFN9bn` then reports `phase: backlog`, and `status`
lists it second in `backlog` with `plan` still holding only
`3IPXRRd2`.

The code is the correct half; the words around it are the wrong half:

- `_work/gitverbs.tl:223` — the message literal, `" — %s was its last
  open child, so %s returns to plan"`.
- `_work/gitverbs_test.tl:101-110` —
  `test_done_returns_a_finished_container_to_backlog` asserts
  `phase == "backlog"` with the reason "its last child closed, so the
  container returns to backlog". The behaviour is pinned; only the
  string is unpinned, which is why the gate is green.
- `_work/gitverdict.tl:179` — the same claim as a code comment above
  the `gate.rephased_parent` call ("returns to plan").

The prose on `main` disagrees with itself the same way:
`.claude/skills/work/SKILL.md` says "returns to `backlog` in the
closing commit"; `.claude/skills/work/review.md` says "returns that
container to `plan` in the same commit, where a later refine verifies
its stated outcome". Whichever is intended, three of the four
statements are wrong today.

Two candidate resolutions, and picking between them is the refinement:
correct the message, the comment and `review.md` to say `backlog`
(cheapest, and matches the code and the test), or decide the container
really should land in `plan` and change `gate.rephased_parent` — which
would put a container into a WIP-limited phase automatically, so the
limit could refuse the landing that causes it.
