# friction: 2026-09-04 work9 (/work 9 --routine)

## orchestrator
- goal: bootstrap the board worktree per skills/work/SKILL.md before opening the friction
  log, then run `sync`.
  actually happened: the bootstrap sequence (worktree add, build, `sync`) had already run
  as the first board verbs before this log file was opened — the friction doctrine
  (skills/work/friction.md) says "opened before the first board verb runs", but the
  bootstrap itself is unavoidable before a log location even exists (no worktree, no
  `o/bin/gitboard` yet to know the scratch dir conventions from). ~3 tool calls
  (worktree add, build, sync) ran before this file existed.
  contributed: skills/work/SKILL.md's bootstrap section and friction.md's ordering rule
  are both correct in isolation, but nothing tells a cold session (no board worktree at
  all) to touch-create the friction log file before running the worktree/build/sync
  commands that bootstrap requires.
  improvement (candidate 1): skills/work/friction.md could say explicitly that the log is opened before
  the first *post-bootstrap* board verb (i.e. after `sync`, before `next`/`take`), since
  bootstrap (worktree add, build) has no log location to write to yet and `sync` itself is
  the tool's own idempotent state-refresh, not a work-selecting action. stays here for
  triage: low-cost, one-sentence doc clarification, not clearly worth its own item.

- goal: fill the wave's spare width with disjoint builds after reconciling the previous
  wave (two accepted PRs, #1680 and #1681, both merged during this pass — #1680 by hand
  after a 405 "in the merge queue" on the first attempt settled, #1681 left to the queue
  since a second wait would have been polling).
  actually happened: `next` and its three `or: pull` alternates named only items from one
  cluster — «Elus_cLzz», «FacE_b8sh», «rNh1_b1Se» — all with `## Change` sections naming
  `_work/brief.tl` and/or `_work/brieftext.tl`, the same files the already-`building`
  «RxN2_253n» touches. A `git grep -l` across `items/*.md` for those two paths found five
  more open items with the same collision (`XsHJ_6fGm`, `4mpH_hi6v`, `qWfP_VKKJ`,
  `WyFa_GL3c`, plus the ones already named) — eight open items total contending for two
  files, one of them (`_work/brieftext.tl`) already at 3 lines of headroom under its
  500-line cap per «rNh1_b1Se»'s own spec. Cost: 6 tool calls (4 full `show` reads
  compared by eye, then the `grep -l` to confirm the pattern held beyond `next`'s 3
  alternates) to conclude that zero of the four items `next` was willing to offer were
  safely poolable this pass. Pulled nothing; doing stayed at 4/10 with real spare
  capacity unused.
  contributed: `gitboard help orchestrate`'s disjointness rule puts the burden on the
  orchestrator to notice a file collision before spawning a wave, but neither `next` nor
  `show` surfaces it — an item's `## Change` section is free text, and cross-referencing
  eight of them by hand is the only way to find the cluster today. Also contributing:
  several distinct concurrent `/work 9 --routine` sessions on this same board period
  each independently mined friction from the same brief/session system and filed
  overlapping-scope fixes without checking what else already named the same file.
  improvement: a tool-level gate — `show`/`next` compute and print file overlap between
  open items' `## Change` sections — beats a doc note, since it transfers to every future
  session and every future collision automatically rather than relying on an
  orchestrator to grep for it. Passes the spec bar; filed as «HKdD_OAYN».

- goal: merge two `accepted` items found on reconciling this pass's opening `show`
  («cOu8_PnMv» pr:1680, «xcBt_YwKh» pr:1681 — both already carried accept verdicts from
  concurrent sessions before this pass's first board verb).
  actually happened: `mcp__github__merge_pull_request` on #1680 returned `405 Pull
  Request is in the merge queue` on the first call — a concurrent session (or GitHub's
  own auto-merge, enabled at accept time) had already enqueued it; re-checking
  `pull_request_read get` a few calls later showed it `merged: true`. `done cOu8_PnMv`
  then refused with "nothing to record... leaves the board unchanged" — a second
  concurrent session had already called `done` on it between my merge-queue check and my
  `done` call. #1681 hit the identical 405 and was left unmerged/un-`done` rather than
  polled a second time.
  contributed: this board is worked by multiple concurrent `/work 9 --routine`
  orchestrator sessions in the same window (independently confirmed by the friction log
  «eAtr_TQDr» already on the board before this pass started, and by `doing` shrinking
  from 7→6→4 across three `show` calls in this pass with no action from this session).
  `gitboard done`'s merge-queue interaction is inherently racy across sessions this way,
  but the tool already treats a no-op `done` as a clean refusal rather than an error, so
  the actual cost here was small (one extra `pull_request_read` call, no retries).
  improvement: not clearly worth a countermeasure — the refusal message correctly named
  the no-op and cost one extra read; polling the merge queue would be worse than the
  status quo. Stays here for triage, not filed.

## candidates
- gitboard show/next: surface file overlap between open items' Change sections —
  filed as «HKdD_OAYN»
- friction.md's "opened before the first board verb" ordering doesn't account for
  bootstrap having no log location yet — stays here for triage: cheap one-sentence
  doc clarification, not clearly worth its own item
- `done`'s races against concurrent sessions calling it on the same merged PR — stays
  here for triage: the tool's existing no-op refusal already handles it cleanly, no
  clear improvement identified
