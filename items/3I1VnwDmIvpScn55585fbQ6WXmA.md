Imported from whilp/cosmic#1229.

## Goal

G8 — the flow system. A WIP limit exists to cap work in progress. `work:plan`
currently counts untriaged evidence against that cap, so capturing a finding
consumes a refinement slot even though nobody has decided the finding is work
yet. The doctrine already says filing is never refused; the counting does not
agree with it, and the disagreement blocks the planner's own intake.

This is the epic exemption, applied to the other thing in `plan` that is not work
in progress. `_work/model.tl` already states the principle in the doc comment
above `counts_against_limit`:

> Whether an issue occupies a WIP-limit slot in a phase: false exactly for an
> epic sitting in plan, true otherwise. An epic is a container that lives in plan
> until every child closes — not work in progress — and counting it against the
> limit starves the phase.

An untriaged `work:finding` is the same shape: it has no goal trace (the hard
rules exempt it from tracing "only until triage"), nobody is refining it, and it
leaves `plan` by adoption or by closure, not by reaching the ready bar.

The tree facts this rests on, re-measured 2026-08-17 against `origin/main`
(board occupancy is deliberately NOT pinned here — it changes hourly, so it is
stated as a measurement below rather than as a fact the ready-bar lint re-runs):

```facts
$ grep -n 'local function counts_against_limit' _work/model.tl
114:local function counts_against_limit(issue: Issue, phase: string): boolean
$ grep -c 'issue.epic' _work/model.tl
1
$ grep -c 'finding: boolean' _work/model.tl
1
$ grep -n '(+%d epics)' _work/verbs.tl
134:      print(("%s %d/%d (+%d epics)"):format(phase, counted, model.LIMITS[phase], exempt))
$ grep -n 'local planning = oldest_first' _work/model.tl
400:  local planning = oldest_first(board, "plan")
$ grep -n 'kind = "refine"' _work/model.tl
403:      kind = "refine",
```

`issue.epic` appears exactly once in the model — inside `counts_against_limit` —
which is what makes this a one-disjunct change rather than a sweep. `Issue`
already carries `finding: boolean`, so the field this needs is modelled and
merely unused by the counting path.

**Measured on the board of 2026-08-17**, after that day's review session:
`plan 24/12 (+7 epics)`. The 31 issues in the phase are 7 epics (already exempt)
+ 9 findings + 11 enable + 4 plain slices; counted, 24. Exempting findings makes
it **15/12** — still over, because the phase genuinely is overloaded with adopted
work. That is the point: the exemption does not make the number look better, it
makes the number *mean* something, so the remaining overage is a real signal to
drain toward `ready` (1/12 at the same moment) rather than an artifact of
counting evidence as work.

## Change

**1. Exempt findings from the plan count.** `_work/model.tl:114-116`:

```teal
local function counts_against_limit(issue: Issue, phase: string): boolean
  return not (phase == "plan" and (issue.epic or issue.finding))
end
```

Extend the doc comment above it with the finding rationale and the measured
composition from the block above, matching the empirical-basis style already
used for `LIMITS`. The `counted()` helper is the single counting path every WIP
check and display shares, so the exemption applies everywhere at once — no other
call site changes.

**Remove the disjunct this makes dead.** `admits_over_limit` (`_work/model.tl:141-147`)
currently reads:

```teal
return not counts_against_limit(issue, to)
or issue.finding
...
```

Once `counts_against_limit` returns false for a finding in `plan`, the first
disjunct subsumes `or issue.finding` for the only phase where it mattered.
Delete that line rather than leaving logic no input can reach. Admission and
occupancy stay two distinct questions — this deletes a redundancy, not the
distinction.

**2. The status line must name both exemptions.** `_work/verbs.tl:134` hardcodes
`(+%d epics)`, which becomes a lie the moment findings are exempt too. Render the
exempt classes it actually found, e.g. `plan 15/12 (+7 epics, +9 findings)`.
Keep the single-class and zero-exempt forms readable.

**3. `next --role planner` must not offer a finding as a refine target.**
`_work/model.tl:400` takes `oldest_first(board, "plan")[1]`, which today can hand
the planner an untriaged finding and tell it to "refine a plan issue toward the
bar" (`kind = "refine"` at `:403`). A finding is a TRIAGE target, not a refine
target: the planner adopts it (add the goal trace, drop the marker) or closes it.
Add a `triage` action kind between `refine` and `intake` — refine what is already
adopted first, then triage held evidence, and only then work backwards from goals
for new work. The refine step filters findings out of its candidate list.

The `triage` action's reason string tells the planner to adopt or close; nothing
gates adoption — see Non-goals for why.

**4. `--enable` refused at the limit names the capture route.** The refusal at
`work-new: REFUSED (plan N/12 at limit; ...)` should also say that evidence can be
captured now and adopted at triage, instead of leaving the caller to invent the
detour.

**5. `status` gains the pressure that replaces the limit.** An exempted class
needs a different pressure or it becomes a landfill — epics self-drain when their
children close, findings do not. `status` prints the finding count and the age of
the oldest alongside the phase line, in the same `cmd_status` edit as item 2.

## Non-goals

**Do not add the `stats` triage-latency metric here.** Reporting filed →
adopted-or-closed latency needs a new derivation over `work:finding` label
add/remove events in `_work/stats.tl`, which is more code than items 1–5
combined and is independently verifiable. It is a follow-up child, not part of
this slice; item 5's `status` counter is the pressure that ships now.

**Do not add a new phase.** A `work:inbox` to the left of `plan` was considered
and rejected: the `work:finding` marker plus the existing `counts_against_limit`
hook already express the distinction, and a phase would touch `PHASES`, the pull
order, the label set, and every verb. Revisit only if the finding counter shows
the marker is not enough.

**Do not change any number in `LIMITS`.** `plan` stays 12. The hard rules forbid
widening a limit to make a move succeed, and after this change `plan` sits at
15/12 — the limit correctly reporting a real overload. The response to that is
draining toward `ready`, not a bigger cap.

**Do not gate adoption on `plan` slack.** The original item 3 asked for it and
there is no seam to hang it on: there is no adopt verb — adoption is dropping the
`work:finding` label plus adding a goal trace to the body, and `_work/verbs.tl`
has only `cmd_status`/`cmd_next`/`cmd_check`/`cmd_move`/`cmd_new`/`cmd_edit`, so
no code path observes an adoption happening. Confirmed from the other side on
2026-08-17, when a planner adopting #1245 at triage had to make a hand-rolled
label call for exactly that reason. A gate here is blocked on an adopt verb
existing — the board-tool write-verb gap tracked in #1204 — and this slice must
not build one.

**Do not exempt `work:enable`.** A planner-filed countermeasure has a goal trace
and is adopted work; it belongs in the count.

**Do not change the finding's tracing exemption, the never-refused write, or any
other phase's counting.** `counts_against_limit` gains one disjunct and nothing
else moves.

## Acceptance

- `bin/cosmic --make test _work/model_test.tl` ends `test: PASS`, with new cases
  pinning: a finding in `plan` does not count; a finding in any other phase DOES;
  an enable issue in `plan` counts; an epic still does not; and
  `admits_over_limit` still admits a finding into `plan` with the disjunct gone.
- `bin/cosmic --make test _work/render_test.tl` ends `test: PASS`, with a case
  pinning the multi-class exempt render (`(+N epics, +M findings)`), the
  single-class form, and the zero-exempt form.
- `bin/cosmic --make run _work/board.tl status` prints a `plan` line whose
  counted total equals the number of issues in the phase carrying neither the
  epic nor the finding marker, and whose exempt suffix names both classes with
  their counts. Assert the invariant against the live board, not a fixed number
  — the board moves hourly and a literal count would be stale before this is
  implemented.
- `bin/cosmic --make run _work/board.tl next --role planner` never returns a
  `refine` action naming a `work:finding` issue; with findings present and
  nothing else to refine it returns a `triage` action instead.
- At the limit, `--enable` intake is refused and the refusal message names the
  capture route. (The under-limit half of this bullet is struck: `plan` has been
  over its limit continuously since this card was written, so a literal run would
  create a junk issue rather than demonstrate anything. Quote the refusal only.)
- The doctrine prose item 3 falsifies is corrected in the same PR:
  `skills/work/SKILL.md`'s planner rule list names the `triage` step between
  refine and intake; its refine step says the oldest non-finding `work:plan`
  issue; and `skills/work/review.md` no longer places finding triage "at the
  refine step". `grep -c triage skills/work/SKILL.md` is greater than 0.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed — the blocker is cleared and the seams exist.

`Blocked by: #1193` is struck: #1193 closed as completed 2026-08-17 via PR #1231
(`76b09cb`), and the `close` verb is on main (`_work/board.tl`, `_work/close.tl`).
That was the hard prerequisite — triage is adopt-or-close, and shipping the
exemption without a close verb would have converted a visible pile into an
invisible one. It now exists, so the drain this change depends on is performable.

Nothing else: `counts_against_limit` is an existing seam with an existing test
file, the render change is one format string in a function that already computes
`exempt`, and the planner-rule change is one filter plus one new action kind in a
function that already returns typed `NextAction` records.

## Adoption note

Adopted from `work:finding` at triage on 2026-08-17: goal trace stated above
(G8), marker removed, facts block re-measured against `origin/main` (six line
numbers had drifted under PR #1234), the stale "makes it 12/12" claim corrected
to the honest 15/12, `Closes #1210` struck (#1210 closed via PR #1234, which
added `--mandated`), and item 5's `stats` half cut to Non-goals as a follow-up
child so the slice fits one session.

---
_Generated by [Claude Code](https://claude.ai/code)_