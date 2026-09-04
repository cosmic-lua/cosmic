## Evidence

Measured in the `/work 9 --routine` pass on 2026-09-04 (friction log
`friction-2026-09-04-work9.md`, filed alongside this item). The
orchestrator's bootstrap for a research-slice handover
(`gitboard take c5wU_p1n9` then `gitboard take c5wU_p1n9 --result`,
neither with `--session`) recorded the item's `claim` field as the
orchestrator's own bare `CLAUDE_CODE_SESSION_ID`. Minting a distinct
review session (`--session review-c5wU_p1n9-3`) for the same item only
updates the item's separate `reviewer` field (`_work/gittake.tl:62`),
not `claim`. Once the bare session held that one claim, every
subsequent `gitboard take <other-item>` call under the default
(no `--session`) identity was refused:

```
gitboard-take: REFUSED: 1e1a9125-9fe7-5933-bfa6-da600fedba86 already
holds 3IosEPKw — one claim per worker; drop it or finish it first
```

Cost: 4 failed `take` calls across 4 unrelated, file-disjoint build
items, plus time spent reading `_work/gittake.tl`/`_work/action.tl` to
understand the refusal, before retrying successfully with an explicit
`--session build-<handle>` on each. `gitboard help orchestrate` already
says to claim "with a distinct minted session name per agent," but
`gitboard help take`'s `--session` option text ("Omit to derive it from
the environment") reads as a convenience default, not a warning that
omitting it burns the orchestrator's only claim slot for the rest of
the pass.

## Change

`gitboard help orchestrate` (`_work/doctrine.tl`, the "Claim first, then
spawn" bullet) and `gitboard help take`'s `--session` option text each
gain one sentence: the orchestrator's own bare session is a single
global claim slot, so every `take` it issues — pull, research handover,
or review claim — MUST pass an explicit `--session <kind>-<handle>...`;
taking under the default derived session locks the orchestrator out of
every further `take` until that one item is dropped or done.

## Non-goals

Not a tool-level guard (e.g. `take` refusing a bare, un-prefixed
session id) — that would need to distinguish a legitimate solo
session's own bare-session claim (fine; it holds one item and drops
it before pulling another, same as `--session` would) from an
orchestrator's, which the tool cannot tell apart. Doc-level fix only.
