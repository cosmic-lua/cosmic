Found while reading board flow on 2026-08-24 at 14:30 UTC.

`next --session NAME` withholds a verdict on work NAME claimed — the review
distance the board depends on. That distance holds only if distinct sessions
pick distinct names, and nothing makes them.

Nine consecutive hourly sessions today all self-named `magical-bell`, each
running on its OWN branch (`claude/magical-bell-daqw6i`, `-6ukmbl`, `-ntrn1b`,
`-bbbsw7`, `-bk8kul`, `-6ityeh`, `-3fm6i5`, `-74byv9`): the assigned branch
carries a unique suffix, and every session dropped it when naming itself,
keeping only the adjective-noun half. So nine genuinely distinct sessions
present to the board as one, and each refuses to review the previous eight as
if it had built them.

The claims, in order (from the board log's `ready -> do` commits):

    00:41  3IKuRFN5  claude-sched-2026-08-24T0038
    02:42  3ILE1xUd  qmnmv1
    03:05  3IK8ACfA  claude-sched-2026-08-24T0238
    06:42  3IK8ARKq  magical-bell
    07:43  3IK30GoH  magical-bell
    08:44  3IK8FzsU  magical-bell
    09:39  3IK8EOci  magical-bell
    10:38  3IK30UQA  magical-bell
    11:39  3IM89fv4  magical-bell
    12:41  3IK30m8u  magical-bell
    12:49  3IHHK1Bj  magical-bell
    14:16  3IMiflQz  magical-bell

Effect on flow, same day: while names were unique (00:38-04:55) five verdicts
were recorded and four items landed. From 06:42 on, zero verdicts on anything
those sessions built. `check` went 1 -> 9 against its limit of 10, with 13
arrivals and 5 departures across the day, while `ready` and `do` sat empty and
`plan` held one blocked item. The eight queued PRs are green and untouched
since creation (sampled: #1350 green since 06:57, #1356 green since 12:47).

`docs/flow-review.md` already names this state exactly, under the `check`
tripwire: "peak reaches 10 with a mix of claims; all from ONE session is the
handover stall, not a limit signal." The instrument called it; nothing acts on
it. One more arrival hits the limit, and then a session that finishes a slice
cannot hand it over at all.

Shapes for whoever refines this:

- gitboard derives a default session identity when `--session` is absent or
  ambiguous (git branch, worktree path, or a per-process id), so the name
  cannot be got wrong by a session paraphrasing its own branch;
- `status`/`next` report the handover-stall shape directly — "N in check, all
  claimed by one session" is a health finding the tool can compute, and today
  only a human reading the log found it;
- the `work` skill says what a session name must BE (unique per run, derived
  from something already unique) rather than leaving `<name>` to taste.

Related, already on the board: 3IEv60qj (land has no lease and no exit check).
