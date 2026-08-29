## Change

`gitboard verdict` verifies the head it records: against the PR when
the board can read one, and against a sane shape always.

Reproduced 2026-08-29 on a scratch board (board head f10c9b6):

    GITBOARD_SESSION=rev-1 gitboard verdict ID accept --pr 7 --head deadbee
    gitboard-verdict: accept on 3Ib1Jdko: awaiting merge — land it

— and `items/ID.tl` then carries `["verdict_head"] = "deadbee"`, a
fabricated head. The whole verdict-pair mechanism (re-review
detection, `done`'s moved-head warning) keys on this field, and
nothing checks it at the only write site.

The change, in two files:

1. `_work/review.tl` (a pure module): add

       head_refusal(p: gh.Pull | nil, head: string): string | nil

   returning a refusal when `head` is not 7-40 lowercase hex
   characters, or when `p` is non-nil and `p.head_sha` does not
   start with `head` (the caller may pass a short sha; the PR's
   full head is the truth it must prefix-match). Pure and
   unit-testable — no gh call inside.
2. `_work/gitverdict.tl` (180 lines now —
   `wc -l < _work/gitverdict.tl`): in `cmd_verdict`, before the
   pair guard, apply the shape half of `head_refusal` always; and
   when `store.has_origin(s)`, read the PR (`gh.pull`, exactly as
   `done`'s accepted path does) and apply the full check — a read
   failure is itself a refusal, because a gate that waves things
   through when it cannot see is worse than no gate. When the check
   passes against a read PR, record the PR's FULL `head_sha` as
   `verdict_head` rather than the caller's prefix, so the stored
   field is canonical. A local-only board (no origin — every
   existing test fixture) skips the PR read and keeps today's
   behaviour past the shape check.

Tests: `_work/review_test.tl` covers `head_refusal` pure — too
short, non-hex, mismatched prefix, matched prefix, nil PR;
`_work/gitverdict_test.tl` pins that a malformed `--head` (the
reproduced `deadbee` is 7 hex chars and SHAPE-valid, so use `xyz`
and a 6-char sha) refuses before any commit, and that the existing
local-board verdicts still land unchanged with a well-formed head.

## Non-goals

Existing verdict-line formats and the pair guard are unchanged; the
new refusals are additions in the standing `REFUSED: ...` shape. No
correction verb for an already-recorded wrong head (that is
3IVRNCFB's remaining half, filed separately). `--head` stays
required; no default is derived from the PR, because the field
records what the reviewer JUDGED, not what happens to be current.
