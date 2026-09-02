## Evidence

Found by the fresh-context review of cosmic-lua/cosmic#1625 (item
3Il47Nxg, board `3d435c5c`), walking a research handover (`take ID
--result`) through the verbs on a scratch store after that PR fixed
the four readers its spec named. Three adjacent readers on the same
path still speak PR-only:

1. `_work/gitgate.tl:240` — the take refusal reads "%d diff(s) await
   a verdict you can give and outrank this take" when what awaits is
   a research handover (the count includes result items, the noun
   does not).
2. `_work/action.tl:178` gives an accepted handover the finish reason
   "is accepted, awaiting merge — finishing beats starting", and
   `_work/gitverdict.tl:243` prints the accept outcome "awaiting
   merge — land it"; the `finish` note in `_work/guidance.tl:33-34`
   then says "`done ID` verifies the PR its `pr` field names is
   merged". A handover has no PR: `done` (`_work/gitverbs.tl:374`)
   skips the merge read when `pr` is 0, so the behaviour is right and
   only the wording sends the session looking for a merge.
3. `_work/gitshow.tl:112` prints `verdict: accept (head , spec
   unchanged since)` — an empty head, because a handover's verdict
   carries no `verdict_head`.

Re-measure at pull time on a fixture: `take ID --result --session S`,
then `take OTHER --session T` (refusal wording), `verdict ID accept
--session R` (outcome line), `next --session S` (finish reason and
guidance), `show ID` (verdict line).

## Change

Board-tooling change on the `board` branch of cosmic-lua/cosmic, as a
PR against base `board`:

- `_work/gitgate.tl`: the take refusal counts what awaits by kind and
  names it — "%d item(s) await a verdict" is acceptable, or "diff"
  / "handover" chosen by `first.result ~= ""`; the wording must not
  say "diff" for a handover.
- `_work/action.tl` and `_work/gitverdict.tl`: for an item with
  `result ~= ""` the accept reason/outcome says "accepted — `done ID`
  ends it" (no merge to await); the PR wording is unchanged.
- `_work/guidance.tl`: the `finish` notes for a handover (via the
  existing `lines(kind, it)` per-item selection from #1625) say `done
  ID` ends an accepted handover directly; the PR note is unchanged.
- `_work/gitshow.tl`: for a handover the verdict line prints
  `verdict: accept (result <7 hex>, spec unchanged since)`; the PR
  form is unchanged.
- One test per reader on a result-item fixture (`gitgate_test`,
  `action_test`, `gitverdict_test`, `guidance_test`, `gitshow_test`).

## Non-goals

- No change to `done`'s behaviour, `substate`, `take`, or the brief
  templates.
- Not extending the readers to any other item kind.
