## Evidence

`move ID check --evidence` — landed 2026-08-26 as PR #1417 (`board`
`c2b5edde`), the whole point of which is a handover that carries no PR
— is unreachable on the real board. The FIRST attempt to use it, on
item `3ISWHyP7` at `board` `a1be06e5` (the machinery is unchanged since `c2b5edde`, and `git log --oneline c2b5edde..a1be06e5 -- _work/` prints nothing), was refused:

```
$ o/bin/gitboard move 3ISWHyP7 check --evidence
gitboard-move: REFUSED: cannot read PR #0: GET /repos/whilp/cosmic/pulls/0:
  HTTP 404: Not Found; --force to hand it over anyway
```

The cause, read at `board` `a1be06e5` (the machinery is unchanged since `c2b5edde`, and `git log --oneline c2b5edde..a1be06e5 -- _work/` prints nothing):

- `_work/gitverbs.tl:151-157` — every move to `check` that is not
  forced calls `gate.handover_refusal(s, id, (pr or 0) ~= 0 and pr or
  it.pr, it.repo)`. PR #1417 added the `--evidence` branch ABOVE this,
  at `_work/gitverbs.tl:127-140`, and left this call unconditional, so
  an evidence handover reaches it with `number = 0`.
- `_work/gitgate.tl:171-193` — `handover_refusal` returns nil only
  when `store.has_origin(s)` is false; otherwise it calls
  `gh.pull(s, 0, repo)`, which 404s, and a failed read is deliberately
  a refusal rather than a silent pass.

So the only way an evidence handover completes today is `--force`,
which the `work` skill reserves for repair, not flow — and forcing
also skips the `## Result` check that `--evidence` exists to impose.

**Why the tests did not catch it.** `_work/gitverbs_test.tl`'s new
`test_check_takes_an_evidence_handover_only_when_asked` passes because
its fixture store has no origin, so `handover_refusal` returns nil at
its first line and the GitHub path never runs. Every existing handover
test is in the same position. The gap is therefore not one missing
assertion but a class of gate that is inert under test — worth stating
in whatever fix lands.

**The shape of the fix** (for the session that specs this): skip
`handover_refusal` when the handover is an evidence one — the same
condition the refusal branch above already computes — rather than
teaching `handover_refusal` about PR #0, so the "a gate that waves
things through when it cannot see is worse than no gate" property it
documents stays true for every PR-carrying handover.

**Blast radius**: `3ISWHyP7` (this board's first evidence slice) is
blocked on it in `do`, its measurement complete and its spec written
to hand over. Nothing else uses `--evidence` yet.

Measured 2026-08-26 from `o/board` at `board` `a1be06e5` (the machinery is unchanged since `c2b5edde`, and `git log --oneline c2b5edde..a1be06e5 -- _work/` prints nothing).
