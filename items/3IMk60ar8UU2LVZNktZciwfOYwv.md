# Status: the identity half shipped; this item is now the detection half

The root cause and its fix (DERIVE the identity instead of trusting a
typed name) shipped 2026-08-24:

- `gitboard` derivation — `_work/session.tl` + wiring in `next`,
  `verdict`, and `do`/`check` `move`s — landed on the `board` branch,
  commit `c646e43c`, board `--make ci` green.
- the `work` skill's "always pass `--session <name>`" instruction, which
  invited the collision, became "run `gitboard next` and let the tool
  derive the identity" — PR #1358 (in review).

An omitted `--session`/`--claim` now yields a unique per-run identity, so
the collision below cannot recur through the ordinary path. What is NOT
yet built is the alarm: when a collision DOES happen (a runner setting no
usable id and a prompt still passing a shared name), nothing computes or
reports it. That is this item's remaining work.

## Remaining problem

`docs/flow-review.md` names the shape under the `check` tripwire — "peak
reaches 10 with a mix of claims; all from ONE session is the handover
stall, not a limit signal" — but nothing computes it. On 2026-08-24 the
stall (nine `check` items, all claimed `magical-bell`, none reviewable)
was found only by a human reading the git log. The board should surface
its own health finding: N items in `check` all carrying one claim is a
handover stall, distinguishable from a healthy mix, and the tool has
every fact to say so.

## Change (remaining)

`_work/health.tl` (the board's own health reader, already surfaced by
`status`) gains a check: when `check` holds items and every claim among
them is the same non-empty session, report it as a distinct finding —
"N in check, all claimed by <session>: handover stall (a reused session
identity, see 3IMk60ar)". `status` already prints health findings; this
is one more, computed from the board it already reads. Threshold and
exact wording are the refiner's to set against `docs/flow-review.md`'s
tripwire language.

## Original evidence (the collision this fixed)

The debug that produced the identity fix, kept for the record:

---


## What went wrong

Nine consecutive scheduled sessions today all self-named `magical-bell`, each
running on its own branch (`claude/magical-bell-daqw6i`, `-6ukmbl`, `-ntrn1b`,
`-bbbsw7`, `-bk8kul`, `-6ityeh`, `-3fm6i5`, `-74byv9`). Nine distinct sessions
present to the board as one, and each refuses to review the previous eight as
if it had built them.

`magical-bell` is not a session name. It is the REPO's branch slug:

- one session, id suffix `3fm6i5`, was assigned `claude/magical-bell-3fm6i5`
  in whilp/cosmic and `claude/wizardly-rubin-3fm6i5` in whilp/cosmopolitan.
  The slug differs per repo; the suffix is the same. So the suffix is the
  session and the slug is the repository.
- the slug is long-lived, not per-run and not per-day: `zealous-hypatia`
  covers 2026-08-20 (`-uiab8f`, commit 4ec56c6a) through 2026-08-22
  (`-s542rw`, commit 28a3fe3e), four branches; `magical-bell` covers
  2026-08-24, eight. Collisions therefore span a multi-day rotation window,
  not one day's runs.

A session reading "Develop on branch `claude/magical-bell-74byv9`" and asked
for a `<name>` takes the readable half. That is exactly backwards: the
readable half is the shared part.

## Why nothing caught it

`--session` has no default, no validation, and no uniqueness check
(`_work/gitboard.tl:184`: `d.parsed.values["session"] or ""`). Every session
invents its own convention, and the board's claim strings show it — 39
distinct values across at least eight schemes: bare suffix (`qmnmv1`,
`xmaezt`, `piji6k`), prefixed suffix (`sched-n4i2ns`, `claude-3gubgy`,
`claude-scheduled-wua6n3`), timestamps (`claude-sched-2026-08-24T0038`), a
stray display marker (`@sched-s542rw`, which renders as `@@sched-s542rw`), and
non-unique labels (`magical-bell` x9, `orchestrator-20260817` x4,
`scheduled-work-session`). Sessions on 08-20 and 08-22 used the suffix;
sessions from 06:42 on 08-24 used the slug. Same instructions, different
taste.

## The damage is durable

`builders` records every session that ever held the claim, precisely so "no
session accepts its own work" survives a handover (`_work/action.tl:146`,
`built_by`). All nine items in `check` carry `["builders"] = "magical-bell"`,
so they are permanently unreviewable by anything named `magical-bell` —
including every future session, which keeps drawing `magical-bell-*` branches
while the slug stands.

## Effect on flow, 2026-08-24

While names were unique (00:38-04:55): five verdicts, four items landed. From
06:42 on: zero verdicts on anything those sessions built. `check` went 1 -> 9
against its limit of 10, 13 arrivals against 5 departures, while `ready` and
`do` sat empty and `plan` held one blocked item. The eight queued PRs are
green and untouched since creation (sampled #1350 green since 06:57, #1356
since 12:47).

`docs/flow-review.md` already names this state under the `check` tripwire:
"peak reaches 10 with a mix of claims; all from ONE session is the handover
stall, not a limit signal." The instrument called the shape; nothing computes
it, so only a human reading the log found it. One more arrival hits the limit,
and a session that finishes a slice cannot hand it over at all.

## Shapes for whoever refines this

- gitboard derives the identity instead of accepting a name on faith: an
  env-provided session id, else the full branch ref including its suffix, else
  a per-process id. A session that cannot get its own name wrong cannot
  collide. Note every session already writes a unique one into its commits —
  the `Claude-Session: https://claude.ai/code/session_<id>` trailer
  (`01HvgX6KLk9UrgPYqFH1kwPh` on 08-20, `01KXW15nhxe6kUfXPWFCECpL` on 08-22).
- gitboard refuses or warns when a `--session` value already appears in
  `builders` on several open items in `check` — the collision is detectable at
  the moment it would do harm.
- `status` computes and reports the handover-stall shape ("N in check, all one
  claim"), so the tripwire the flow review wrote down has an instrument.
- the `work` skill states what a session name must BE — unique per run,
  derived from something already unique — rather than leaving `<name>` to
  taste.

Immediate unblock, independent of any of the above: a session naming itself by
its branch SUFFIX may review all eight it did not build.

Related, already on the board: 3IEv60qj (land has no lease and no exit check).
