## Evidence

Measured 2026-09-03 in the board worktree (`o/board`, branch `board`).

    git log --since="48 hours ago" --format='%h %ci %s' | grep -i "duplicate of"
    d1acb0bc 2026-09-01 21:59  done 3IjZBiAV not-planned (forced: duplicate of ceK6_alfE (3IjZEmpx…), same title, already fixed and merged via PR #330)
    2caf6ea5 2026-09-01 21:27  done 3IivRILs not-planned (forced: duplicate of g37H_bOug (3IjRaU2d…), … PR #321 …)
    de0ab285 2026-09-01 19:14  done 3IivR0lb not-planned (forced: duplicate of g37H_bOug (3IjRaU2d…), … PR #321 …)
    4cddfbb4 2026-09-01 19:14  done 3IivH1Re not-planned (forced: duplicate of zwK6_ZzAh (3IjRZ9hD…), … PR #324 …)
    d75b628c 2026-09-01 16:48  done 3IivGicD not-planned (forced: duplicate of GHwN_mLjA (3IjRXqZe…), … LuaUnixRaise …)

Five closures, one shape. The pairs' titles (`items/<id>.tl`):

    3IjZBiAV / 3IjZEmpx  identical: "cosmopolitan: tool/net/demo/unix-dir.lua still destructures unix.localtime positionally, broken by #321"
    3IivRILs "cosmo.unix: localtime's failure tuple shares slots 2-3 …"   / 3IjRaU2d "cosmopolitan: unix.gmtime and unix.localtime return one table …"
    3IivH1Re "cosmo.unix: unix.sigprocmask's only failure (EINVAL) …"     / 3IjRZ9hD "cosmopolitan: unix.sigprocmask raises on an invalid how …"
    3IivGicD "cosmo.unix: unix.raise's only failure (EINVAL) …"           / 3IjRXqZe "cosmopolitan: unix.raise raises on an invalid signal number …"

In four of five the later mint (the `3IjR…`/`3IjZ…` id) arrived while
the earlier item was still OPEN, so a check against recently-ended
items alone would have missed them; a check against open items by the
binding named (`unix.localtime`, `unix.sigprocmask`, `unix.raise`)
catches all four, and identical-title catches the fifth.

The mint is `_work/gitgraph.tl:42` `cmd_new` (376-line file), reached
from `_work/gitboard.tl:351`; it already loads every item — ended ones
included, `resolution ~= ""` — via `store.list` (`:44`) before
writing. An item has no ended-at field (`_work/item.tl:109-110`); the
board's git log carries it (`done <prefix> …` subjects), reachable
through `store.git(s, argv)` (`_work/store.tl:42`).

## Change

- `_work/dedup.tl` (new, pure): `matches(title: string, items: {Item}, recent_done: {string: boolean}): {Match}`
  where `Match = {id: string, why: string}`. Two tests, either flags:
  1. **title**: lowercase, strip punctuation, drop a fixed stopword
     list, compare token sets; Jaccard ≥ 0.6, or one set contained in
     the other with ≥ 4 tokens.
  2. **subject**: a binding or path token — `unix.<name>`,
     `cosmo.<name>`, `<mod>.<fn>` with a lowercase module prefix, or
     any `[a-z_/]+\.(tl|lua|c)` — present in both titles.
  Candidates: every item with `resolution == ""`, plus every ended
  item whose id prefix appears in `recent_done`.
- `_work/gitgraph.tl` `cmd_new`: build `recent_done` from one call,
  `store.git(s, {"log", "--since=14.days", "--format=%s", "--", "items"})`,
  taking the 8-char prefix after `done `; run `dedup.matches`; on any
  match refuse with `gate.verdict_line("new", false, …)` listing each
  match as `<handle> <why>: <title>`. A new option `--unlike ID`
  (repeatable) names a listed match as not-a-duplicate and lets the
  mint proceed past that one; the acknowledgement is written into the
  new item's spec sidecar as a `## Not a duplicate of` line so the
  reviewer sees it. No `--force`: the doctrine reserves that for repair.
- `_work/dedup_test.tl`: the five pairs above as fixtures (title-only
  hit, subject-only hit, no hit for two unrelated `unix.*` titles);
  `_work/gitgraph_test.tl`: one refused mint, one `--unlike` mint.
- `gitboard help new` and `skills/work/SKILL.md`'s intake paragraph
  name the check in one sentence each.
- The board's own gate passes (`bin/cosmic --make ci` in the worktree).

## Non-goals

Not re-triaging existing duplicates; not scanning spec bodies (titles
are what intake reads first, and the five cases are all title-visible).
