## Evidence

`gitboard brief builder cOu8_PnMv`'s verdict line asked the
orchestrator to fill `<N>`, and `brief builder RxN2_253n`'s asked for
`<REVIEW_SESSION>`; neither is a placeholder of the builder template.
Both strings sit inside the items' own specs (a `take ID --pr <N>`
example; the label placeholder the review brief used to carry), which
the brief quotes verbatim. `_work/brief.tl` finds survivors by
scanning the whole filled text for the `<UPPER_SNAKE>` shape, so any
spec that quotes such a token — every board-tooling item does — makes
the verdict line lie, and an orchestrator following it looks for a
placeholder that is not there (the 2026-09-04 routine log records the
detour on two of six briefs).

## Change

`_work/brief.tl`: the survivor list is the template's own placeholder
set — the names the template source declares (`<WORKTREE>`,
`<BOUNCE_CONTEXT>`, `<HEAD_SHA>`, `<REVIEW_SESSION>`, and whatever else
each kind's text carries) — checked for presence after filling, never
a regex over the filled body. A placeholder-shaped token inside the
quoted spec is spec text and is neither reported nor touched.

`_work/brief_test.tl`: a fixture spec containing `<N>` and
`<REVIEW_SESSION>` in its body yields a verdict line naming only the
template's unfilled placeholders; a fully filled brief names none.

## Non-goals

No change to what the placeholders are or who fills them.
