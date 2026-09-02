## Evidence

Reported by the builder and the two reviews of cosmic-lua/cosmic#1624
(item 3Iivjobs, the `take ID --result` research handover, merged as
board `4f38a8be`). After it a result item ranks as "review" through
`flow.substate`, and four readers written for PRs now meet it with
wording or output that is wrong for a handover:

1. `_work/action.tl:195` gives the review action the reason "a PR
   awaits a verdict — verdicts before new work".
2. `_work/guidance.tl:36-41` tells the reviewer to record
   `verdict ... --pr N --head SHA` — which `_work/gitverdict.tl` now
   refuses for a handover.
3. `_work/gitshow.tl:90` and `_work/gitview.tl:119` print `pr:` only;
   a result item's digest is visible only in the sidecar and the log
   line.
4. `_work/gittake.tl:90-91`'s doc comment says "the SAME spec handed
   over again is a no-op whatever stands on it", but `gittake.tl:127`
   deliberately falls through and clears a `request changes` (the
   `--pr` mirror, asserted at `_work/gitverdict_test.tl:461`); the
   sentence is false, the behaviour is the requested one.

#1624's spec held "no reader edited", so all four stand. Re-measure at
pull time on a fixture: `take ID --result --session S`, then
`next --session T`, `show ID`, and read the reason line, the guidance,
and the show output.

## Change

Board-tooling change on the `board` branch of cosmic-lua/cosmic, as a
PR against base `board`:

- `_work/action.tl`: the review reason branches on `it.result ~= ""`
  ("a research handover awaits a verdict — verdicts before new work").
- `_work/guidance.tl`: the verdict instruction for a result item is
  `verdict ID <accept|request-changes|reject> --session <you>`, no
  `--pr`/`--head`.
- `_work/gitshow.tl` and `_work/gitview.tl`: print `result:<7 hex>`
  where they print `pr:N`, for a result item.
- `_work/gittake.tl:90-91`: the doc comment states the actual rule (a
  same-spec re-handover is a no-op unless `request changes` stands,
  which it clears).
- One test each on a result-item fixture (`_work/action_test.tl`,
  the guidance test, `_work/gitshow_test.tl`/`gitview_test.tl`).
  PR wording untouched.

## Non-goals

- No change to `substate`, `take`, `verdict` or the brief templates.
- Not deciding whether a same-spec re-handover over a send-back
  should return the item to review when the digest did not move (the
  research side can see that; the PR side cannot). That is a design
  question for its own item if it bites.
